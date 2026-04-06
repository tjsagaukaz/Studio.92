// TraceStore.swift
// Studio.92 — Command Center
// SwiftData persistence for agent trace spans.
// Queryable, filterable, and paginated — no ndjson parsing in the hot path.

import Foundation
import SwiftData
import AgentCouncil

// MARK: - Persisted Span

@Model
final class PersistedSpan {

    @Attribute(.unique)
    var id: UUID

    var parentID: UUID?
    var traceID: UUID
    var sessionID: UUID?

    /// Raw kind value (llmCall, toolExecution, subagent, permissionCheck, retry, session).
    var kind: String

    /// Human-readable name (e.g., "claude_stream", "file_read", "subagent_run").
    var name: String

    var startedAt: Date
    var endedAt: Date?

    /// "ok" or the error message.
    var statusText: String?
    var isError: Bool

    /// Flat key-value attributes serialized as JSON.
    var attributesJSON: Data?

    /// Raw tool input payload for replay.
    var inputPayloadJSON: Data?
    /// Raw tool output payload for inspection.
    var outputPayloadJSON: Data?

    /// Computed duration in seconds.
    var durationSeconds: Double? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    init(
        id: UUID,
        parentID: UUID? = nil,
        traceID: UUID,
        sessionID: UUID? = nil,
        kind: String,
        name: String,
        startedAt: Date,
        endedAt: Date? = nil,
        statusText: String? = nil,
        isError: Bool = false,
        attributesJSON: Data? = nil,
        inputPayloadJSON: Data? = nil,
        outputPayloadJSON: Data? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.traceID = traceID
        self.sessionID = sessionID
        self.kind = kind
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.statusText = statusText
        self.isError = isError
        self.attributesJSON = attributesJSON
        self.inputPayloadJSON = inputPayloadJSON
        self.outputPayloadJSON = outputPayloadJSON
    }
}

// MARK: - Trace Persister

/// Observes a TraceCollector's span stream and persists completed spans into SwiftData.
@ModelActor
actor TracePersister {

    private var observationTask: Task<Void, Never>?

    /// Begin observing a TraceCollector and persisting its spans.
    func observe(_ collector: TraceCollector, sessionID: UUID? = nil) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let stream = await collector.spanStream()
            for await span in stream {
                guard !Task.isCancelled else { break }
                await self?.persist(span, sessionID: sessionID)
            }
        }
    }

    /// Persist a single completed span.
    private func persist(_ span: Span, sessionID: UUID?) {
        let attributesData: Data?
        if !span.attributes.isEmpty {
            attributesData = try? JSONEncoder().encode(span.attributes)
        } else {
            attributesData = nil
        }

        let statusText: String?
        let isError: Bool
        switch span.status {
        case .ok:
            statusText = "ok"
            isError = false
        case .error(let message):
            statusText = message
            isError = true
        case nil:
            statusText = nil
            isError = false
        }

        let persisted = PersistedSpan(
            id: span.id,
            parentID: span.parentID,
            traceID: span.traceID,
            sessionID: sessionID,
            kind: span.kind.rawValue,
            name: span.name,
            startedAt: span.startedAt,
            endedAt: span.endedAt,
            statusText: statusText,
            isError: isError,
            attributesJSON: attributesData,
            inputPayloadJSON: span.inputPayload,
            outputPayloadJSON: span.outputPayload
        )

        modelContext.insert(persisted)
        modelContext.saveWithLogging()
    }

    /// Stop observing.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}

// MARK: - Trace Query Helpers

extension PersistedSpan {

    /// Decoded attributes dictionary.
    var attributes: [String: String] {
        guard let data = attributesJSON else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Human-readable label for the span kind.
    var kindLabel: String {
        switch kind {
        case "llmCall": return "LLM Call"
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

    /// Human-readable label for the span name (tool-specific).
    var displayName: String {
        switch name {
        case "claude_stream": return "Claude Stream"
        case "subagent_run": return "Subagent"
        case "subagent_llm_call": return "Subagent LLM"
        case "agentic_loop": return "Agent Session"
        case "context_compaction": return "Context Compaction"
        case "architecture_violation": return "Architecture Violation"
        case "permission_blocked": return "Permission Blocked"
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

    /// Decoded input payload as pretty-printed JSON string.
    var inputPayloadString: String? {
        guard let data = inputPayloadJSON else { return nil }
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: formatted, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Decoded output payload as pretty-printed JSON string.
    var outputPayloadString: String? {
        guard let data = outputPayloadJSON else { return nil }
        if let pretty = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]) {
            return String(data: formatted, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }
}
