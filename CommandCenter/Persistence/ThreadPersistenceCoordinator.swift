// ThreadPersistenceCoordinator.swift
// Studio.92 — Command Center
// Bridges live ChatThread/ConversationStore to SwiftData persistence.

import Foundation
import CryptoKit
import SwiftData

// MARK: - Thread Persistence Coordinator

/// Bridges the live ChatThread/ConversationStore to SwiftData persistence.
/// Call `persist` after each pipeline run completes. Call `loadThread` to hydrate
/// a ConversationStore from a previously saved thread.
@MainActor
final class ThreadPersistenceCoordinator {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Save

    /// Persist the current conversation turns into a PersistedThread.
    /// If a thread already exists for this goal+workspace combo, appends new messages.
    func persist(
        turns: [ConversationTurn],
        goal: String,
        workspacePath: String,
        projectID: UUID?
    ) {
        guard !turns.isEmpty else { return }

        let title = goal.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let thread: PersistedThread
        if let existing = findThread(title: title, workspacePath: workspacePath) {
            thread = existing
        } else {
            thread = PersistedThread(
                title: String(title),
                workspacePath: workspacePath,
                projectID: projectID
            )
            modelContext.insert(thread)
        }

        let existingMessageIDs = Set(thread.messages.map(\.id))

        for turn in turns {
            // Persist user goal
            if !turn.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let userMsgID = deterministicID(threadID: thread.id, turnID: turn.id, suffix: "user")
                if !existingMessageIDs.contains(userMsgID) {
                    let userMsg = PersistedMessage(
                        kind: "userGoal",
                        goal: turn.userGoal,
                        text: turn.userGoal,
                        timestamp: turn.timestamp,
                        epochID: turn.epochID
                    )
                    userMsg.id = userMsgID
                    userMsg.thread = thread
                    modelContext.insert(userMsg)
                }
            }

            // Persist assistant response
            let responseText = turn.response.renderedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !responseText.isEmpty {
                let assistantMsgID = deterministicID(threadID: thread.id, turnID: turn.id, suffix: "assistant")
                if !existingMessageIDs.contains(assistantMsgID) {
                    let toolJSON = encodeToolTraces(turn.toolTraces)
                    let kind: String = turn.state == .failed ? "error" : "assistant"
                    let assistantMsg = PersistedMessage(
                        kind: kind,
                        goal: turn.userGoal,
                        text: responseText,
                        thinkingText: turn.response.thinkingText.isEmpty ? nil : turn.response.thinkingText,
                        toolTracesJSON: toolJSON,
                        timestamp: turn.timestamp.addingTimeInterval(0.001),
                        epochID: turn.epochID
                    )
                    assistantMsg.id = assistantMsgID
                    assistantMsg.thread = thread
                    modelContext.insert(assistantMsg)
                }
            }
        }

        thread.updatedAt = Date()
        if let projectID { thread.projectID = projectID }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            print("[ThreadPersistenceCoordinator] Save failed, rolled back: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    /// Load all threads for a given workspace, most recent first.
    func threads(forWorkspace workspacePath: String) -> [PersistedThread] {
        let descriptor = FetchDescriptor<PersistedThread>(
            predicate: #Predicate { $0.workspacePath == workspacePath },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Load threads linked to a specific project, most recent first, capped at `limit`.
    func threads(forProject projectID: UUID, limit: Int = 5) -> [PersistedThread] {
        let descriptor = FetchDescriptor<PersistedThread>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return Array(all.prefix(limit))
    }

    /// Rehydrate a persisted thread into the conversation store.
    /// Marks all rebuilt turns as historical so live pipeline won't collide.
    func rehydrate(thread: PersistedThread, into store: ConversationStore) {
        let messages = chatMessages(from: thread)
        store.rebuild(from: messages, isPipelineRunning: false)
        store.markAllHistorical()
    }

    /// Fetch a thread by its ID.
    func thread(byID id: UUID) -> PersistedThread? {
        let descriptor = FetchDescriptor<PersistedThread>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Persist to a specific existing thread (continuity guard).
    /// Falls back to the default title-based matching if threadID is nil.
    func persist(
        threadID: UUID?,
        turns: [ConversationTurn],
        goal: String,
        workspacePath: String,
        projectID: UUID?
    ) {
        if let threadID, let existing = thread(byID: threadID) {
            persistInto(thread: existing, turns: turns, projectID: projectID)
        } else {
            persist(turns: turns, goal: goal, workspacePath: workspacePath, projectID: projectID)
        }
    }

    /// Load threads scored by recency + activity for a workspace.
    /// Score: +3 running/just-finished (<2 min), +2 interacted <10 min, +1 today, 0 otherwise.
    func scoredThreads(forWorkspace workspacePath: String, activeJobProjectIDs: Set<UUID>) -> [PersistedThread] {
        let all = threads(forWorkspace: workspacePath)
        let now = Date()
        return all.sorted { a, b in
            threadScore(a, now: now, activeJobProjectIDs: activeJobProjectIDs)
                > threadScore(b, now: now, activeJobProjectIDs: activeJobProjectIDs)
        }
    }

    private func threadScore(_ thread: PersistedThread, now: Date, activeJobProjectIDs: Set<UUID>) -> Int {
        let age = now.timeIntervalSince(thread.updatedAt)
        var score = 0
        // +3 if linked to an active job or updated in last 2 minutes
        if let pid = thread.projectID, activeJobProjectIDs.contains(pid) {
            score += 3
        } else if age < 120 {
            score += 3
        }
        // +2 if interacted within 10 minutes
        if age < 600 { score += 2 }
        // +1 if today
        if Calendar.current.isDateInToday(thread.updatedAt) { score += 1 }
        return score
    }

    /// The single most recent thread across the workspace (for "Resume" anchor).
    func mostRecentThread(forWorkspace workspacePath: String) -> PersistedThread? {
        threads(forWorkspace: workspacePath).first
    }

    // MARK: - Internal Persist

    private func persistInto(thread: PersistedThread, turns: [ConversationTurn], projectID: UUID?) {
        guard !turns.isEmpty else { return }
        let existingMessageIDs = Set(thread.messages.map(\.id))

        for turn in turns {
            if !turn.userGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let userMsgID = deterministicID(threadID: thread.id, turnID: turn.id, suffix: "user")
                if !existingMessageIDs.contains(userMsgID) {
                    let userMsg = PersistedMessage(
                        kind: "userGoal", goal: turn.userGoal, text: turn.userGoal,
                        timestamp: turn.timestamp, epochID: turn.epochID
                    )
                    userMsg.id = userMsgID
                    userMsg.thread = thread
                    modelContext.insert(userMsg)
                }
            }

            let responseText = turn.response.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !responseText.isEmpty {
                let assistantMsgID = deterministicID(threadID: thread.id, turnID: turn.id, suffix: "assistant")
                if !existingMessageIDs.contains(assistantMsgID) {
                    let toolJSON = encodeToolTraces(turn.toolTraces)
                    let kind: String = turn.state == .failed ? "error" : "assistant"
                    let assistantMsg = PersistedMessage(
                        kind: kind, goal: turn.userGoal, text: responseText,
                        thinkingText: turn.response.thinkingText.isEmpty ? nil : turn.response.thinkingText,
                        toolTracesJSON: toolJSON,
                        timestamp: turn.timestamp.addingTimeInterval(0.001),
                        epochID: turn.epochID
                    )
                    assistantMsg.id = assistantMsgID
                    assistantMsg.thread = thread
                    modelContext.insert(assistantMsg)
                }
            }
        }

        thread.updatedAt = Date()
        if let projectID { thread.projectID = projectID }
        modelContext.saveWithLogging()
    }
    func chatMessages(from thread: PersistedThread) -> [ChatMessage] {
        thread.sortedMessages.map { pm in
            ChatMessage(
                id: pm.id,
                kind: chatMessageKind(from: pm.kind),
                goal: pm.goal,
                text: pm.text,
                detailText: nil,
                timestamp: pm.timestamp,
                screenshotPath: nil,
                metrics: nil,
                executionTree: nil,
                epochID: pm.epochID
            )
        }
    }

    // MARK: - Helpers

    private func findThread(title: String, workspacePath: String) -> PersistedThread? {
        let descriptor = FetchDescriptor<PersistedThread>(
            predicate: #Predicate { $0.title == title && $0.workspacePath == workspacePath },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func deterministicID(threadID: UUID, turnID: UUID, suffix: String) -> UUID {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: threadID.uuid) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: turnID.uuid) { Data($0) })
        data.append(contentsOf: suffix.utf8)

        let digest = SHA256.hash(data: data)
        var bytes = Array(digest.prefix(16))
        // Set UUID version 5 and variant bits for RFC 4122 compliance
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func chatMessageKind(from kind: String) -> ChatMessage.Kind {
        switch kind {
        case "userGoal": return .userGoal
        case "assistant": return .assistant
        case "completion": return .completion
        case "error": return .error
        default: return .assistant
        }
    }

    private func encodeToolTraces(_ traces: [ToolTrace]) -> Data? {
        guard !traces.isEmpty else { return nil }
        let summaries = traces.map { trace in
            ["name": trace.sourceName, "status": trace.status.rawValue]
        }
        return try? JSONSerialization.data(withJSONObject: summaries)
    }
}
