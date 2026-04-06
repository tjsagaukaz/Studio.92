// ToolGuardrails.swift
// Studio.92 — CommandCenter
// Single source of truth for tool permission and sandbox policies.
// Mirror of Sources/AgentCouncil/Guardrails/ToolGuardrails.swift
// adapted for the CommandCenter target.

import Foundation
import Combine
import AgentCouncil

enum CommandAccessScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case readOnly = "read_only"
    case workspaceOnly = "workspace_only"
    case fullMacAccess = "full_mac_access"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .readOnly:
            return "Read Only"
        case .workspaceOnly:
            return "Workspace Only"
        case .fullMacAccess:
            return "Full Mac Access"
        }
    }

    var shortLabel: String {
        switch self {
        case .readOnly:
            return "Read only"
        case .workspaceOnly:
            return "Workspace"
        case .fullMacAccess:
            return "Full Mac"
        }
    }

    var symbolName: String {
        switch self {
        case .readOnly:
            return "lock"
        case .workspaceOnly:
            return "folder"
        case .fullMacAccess:
            return "desktopcomputer"
        }
    }

    var summary: String {
        switch self {
        case .readOnly:
            return "Read files and inspect state, but block workspace writes, terminal commands, and shipping actions."
        case .workspaceOnly:
            return "Operate inside the current workspace sandbox with real edits, builds, and verification."
        case .fullMacAccess:
            return "Allow access beyond the workspace when the current approval mode permits it."
        }
    }
}

enum CommandApprovalMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case alwaysAsk = "always_ask"
    case askOnRiskyActions = "ask_on_risky_actions"
    case neverAsk = "never_ask"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAsk:
            return "Always Ask"
        case .askOnRiskyActions:
            return "Ask on Risky Actions"
        case .neverAsk:
            return "Never Ask"
        }
    }

    var shortLabel: String {
        switch self {
        case .alwaysAsk:
            return "Always ask"
        case .askOnRiskyActions:
            return "Risky asks"
        case .neverAsk:
            return "Bypass approvals"
        }
    }

    var symbolName: String {
        switch self {
        case .alwaysAsk:
            return "hand.raised"
        case .askOnRiskyActions:
            return "exclamationmark.shield"
        case .neverAsk:
            return "bolt.shield"
        }
    }

    var summary: String {
        switch self {
        case .alwaysAsk:
            return "Prompt before every mutating action during a run."
        case .askOnRiskyActions:
            return "Allow normal workspace edits, but prompt before shipping and detached background execution."
        case .neverAsk:
            return "Allow all available tools within the selected access scope."
        }
    }
}

struct CommandRuntimePolicy: Sendable, Equatable {

    let accessScope: CommandAccessScope
    let approvalMode: CommandApprovalMode

    static let mutatingTools: Set<String> = [
        "file_write",
        "file_patch",
        "terminal",
        "deploy_to_testflight",
        "delegate_to_worktree"
    ]

    static let riskyTools: Set<String> = [
        "deploy_to_testflight",
        "delegate_to_worktree"
    ]

    static let machineWideSensitiveTools: Set<String> = [
        "file_read",
        "file_write",
        "file_patch",
        "list_files",
        "terminal"
    ]

    var allowsMachineWideAccess: Bool {
        accessScope == .fullMacAccess
    }

    var blockedTools: Set<String> {
        var blocked: Set<String> = []

        if accessScope == .readOnly {
            blocked.formUnion(Self.mutatingTools)
        }

        return blocked
    }

    var permissionPolicy: ToolPermissionPolicy {
        ToolPermissionPolicy(blockedTools: blockedTools)
    }

    var statusLine: String {
        "\(accessScope.displayName) · \(approvalMode.displayName)"
    }

    var compactStatusLine: String {
        "\(accessScope.shortLabel) · \(approvalMode.shortLabel)"
    }

    var promptSection: String {
        let blocked = blockedTools.sorted().joined(separator: ", ")
        let blockedLine = blocked.isEmpty ? "Blocked tools: none." : "Blocked tools: \(blocked)."

        return """

        ### EXECUTION POLICY ###
        Access scope: \(accessScope.displayName)
        Approval mode: \(approvalMode.displayName)
        \(accessScope.summary)
        \(approvalMode.summary)
        \(blockedLine)
        """
    }

    func filteredTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.filter { tool in
            guard let name = tool["name"] as? String else { return true }
            return !blockedTools.contains(name)
        }
    }

    func requiresApproval(toolName: String, resolvedPaths: [String] = [], workspaceRoot: String? = nil) -> Bool {
        guard !blockedTools.contains(toolName) else { return false }

        switch approvalMode {
        case .alwaysAsk:
            return Self.mutatingTools.contains(toolName)
        case .askOnRiskyActions:
            if Self.riskyTools.contains(toolName) {
                return true
            }
            if accessScope == .fullMacAccess,
               Self.machineWideSensitiveTools.contains(toolName),
               hasPathOutsideWorkspace(resolvedPaths, workspaceRoot: workspaceRoot) {
                return true
            }
            return false
        case .neverAsk:
            return false
        }
    }

    func approvalMessage(for toolName: String, resolvedPaths: [String] = [], workspaceRoot: String? = nil, summary: String? = nil) -> String {
        if accessScope == .fullMacAccess,
           let outsidePath = firstPathOutsideWorkspace(resolvedPaths, workspaceRoot: workspaceRoot) {
            return "This action wants to operate outside the current workspace sandbox: \(outsidePath)."
        }

        if Self.riskyTools.contains(toolName) {
            return summary ?? "This action can change external state or launch longer-running work."
        }

        return summary ?? "This action changes local state and requires approval in the current mode."
    }

    private func hasPathOutsideWorkspace(_ paths: [String], workspaceRoot: String?) -> Bool {
        firstPathOutsideWorkspace(paths, workspaceRoot: workspaceRoot) != nil
    }

    private func firstPathOutsideWorkspace(_ paths: [String], workspaceRoot: String?) -> String? {
        guard let workspaceRoot, !workspaceRoot.isEmpty else { return nil }
        return paths.first { !$0.hasPrefix(workspaceRoot) }
    }
}

struct ToolApprovalRequest: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let title: String
    let message: String
    let intentDescription: String
    let actionPreview: String?

    static func == (lhs: ToolApprovalRequest, rhs: ToolApprovalRequest) -> Bool {
        lhs.id == rhs.id
    }
}

struct ApprovalAuditEntry: Identifiable, Sendable {
    enum Outcome: Sendable { case authorized, rejected }
    let id = UUID()
    let title: String
    let actionPreview: String?
    let outcome: Outcome
    let timestamp: Date
}

// MARK: - Action Anchor (Revert Protocol)

/// A lightweight temporal marker created immediately before a diff is applied
/// or a destructive command executes. Persists as a Git ref so it survives crashes.
struct ActionAnchor: Identifiable, Sendable, Equatable {
    enum Kind: Sendable {
        case diffApplied
        case destructiveCommand
    }
    let id: UUID
    let kind: Kind
    let title: String
    /// Short description of what was applied, shown in the temporal revert card.
    let actionPreview: String?
    /// The git commit SHA stored under refs/studio92/anchors/<id>.
    let gitSHA: String
    let timestamp: Date

    init(id: UUID = UUID(), kind: Kind, title: String, actionPreview: String?, gitSHA: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.actionPreview = actionPreview
        self.gitSHA = gitSHA
        self.timestamp = Date()
    }
}

@MainActor
final class CommandApprovalController: ObservableObject {

    static let shared = CommandApprovalController()

    @Published private(set) var pendingRequest: ToolApprovalRequest?
    @Published private(set) var auditLog: [ApprovalAuditEntry] = []

    private var continuation: CheckedContinuation<Bool, Never>?

    func requestApproval(_ request: ToolApprovalRequest) async -> Bool {
        if pendingRequest != nil {
            resolveCurrentRequest(approved: false)
        }

        pendingRequest = request
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func approve() {
        resolveCurrentRequest(approved: true)
    }

    func deny() {
        resolveCurrentRequest(approved: false)
    }

    private func resolveCurrentRequest(approved: Bool) {
        if let request = pendingRequest {
            auditLog.append(ApprovalAuditEntry(
                title: request.title,
                actionPreview: request.actionPreview,
                outcome: approved ? .authorized : .rejected,
                timestamp: Date()
            ))
        }
        pendingRequest = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

@MainActor
final class CommandAccessPreferenceStore: ObservableObject {

    static let shared = CommandAccessPreferenceStore()

    private static let accessScopeDefaultsKey = "studio92.commandAccessScope"
    private static let approvalModeDefaultsKey = "studio92.commandApprovalMode"
    private static let planApprovalModeDefaultsKey = "studio92.planApprovalMode"

    @Published var accessScope: CommandAccessScope {
        didSet { persist() }
    }

    @Published var approvalMode: CommandApprovalMode {
        didSet { persist() }
    }

    @Published var planApprovalMode: PlanApprovalMode {
        didSet { persist() }
    }

    var snapshot: CommandRuntimePolicy {
        CommandRuntimePolicy(accessScope: accessScope, approvalMode: approvalMode)
    }

    private init(defaults: UserDefaults = .standard) {
        let storedAccessScope = defaults.string(forKey: Self.accessScopeDefaultsKey)
            .flatMap(CommandAccessScope.init(rawValue:))
            ?? .workspaceOnly
        let storedApprovalMode = defaults.string(forKey: Self.approvalModeDefaultsKey)
            .flatMap(CommandApprovalMode.init(rawValue:))
            ?? .askOnRiskyActions
        let storedPlanApproval = defaults.string(forKey: Self.planApprovalModeDefaultsKey)
            .flatMap(PlanApprovalMode.init(rawValue:))
            ?? .alwaysReview

        self.accessScope = storedAccessScope
        self.approvalMode = storedApprovalMode
        self.planApprovalMode = storedPlanApproval
    }

    private func persist() {
        UserDefaults.standard.set(accessScope.rawValue, forKey: Self.accessScopeDefaultsKey)
        UserDefaults.standard.set(approvalMode.rawValue, forKey: Self.approvalModeDefaultsKey)
        UserDefaults.standard.set(planApprovalMode.rawValue, forKey: Self.planApprovalModeDefaultsKey)
    }
}

// MARK: - Plan Approval Mode

enum PlanApprovalMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case alwaysReview = "always_review"
    case autoExecute = "auto_execute"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysReview: return "Review Plans"
        case .autoExecute:  return "Auto-Execute"
        }
    }

    var shortLabel: String {
        switch self {
        case .alwaysReview: return "Review plans"
        case .autoExecute:  return "Auto-execute"
        }
    }

    var symbolName: String {
        switch self {
        case .alwaysReview: return "list.bullet.clipboard"
        case .autoExecute:  return "bolt.horizontal"
        }
    }

    var summary: String {
        switch self {
        case .alwaysReview:
            return "Pause before executing multi-step plans so you can review and refine."
        case .autoExecute:
            return "Execute generated plans immediately without pausing for review."
        }
    }
}

// MARK: - To-Do Gate Controller

/// Manages the plan approval lifecycle: the pipeline generates a TaskPlan,
/// pauses here, and resumes only when the user approves or the plan approval
/// mode is set to auto-execute.
@MainActor
@Observable
final class TodoGateController {

    static let shared = TodoGateController()

    /// The plan awaiting user approval. Non-nil triggers the gate UI.
    private(set) var pendingPlan: TodoGateRequest?

    /// Whether the gate is actively blocking a pipeline run.
    var isGateActive: Bool { pendingPlan != nil }

    private var continuation: CheckedContinuation<TodoGateDecision, Never>?

    /// Present a plan to the user and suspend until they approve, refine, or reject.
    func requestApproval(_ request: TodoGateRequest) async -> TodoGateDecision {
        // Guard against double-calls: if a previous request is suspended, reject it
        // before accepting the new one. Without this, the first continuation is
        // overwritten and its caller hangs forever.
        if pendingPlan != nil {
            resolve(.rejected)
        }

        pendingPlan = request
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func approve() {
        resolve(.approved)
    }

    func refine(feedback: String) {
        resolve(.refined(feedback: feedback))
    }

    func reject() {
        resolve(.rejected)
    }

    private func resolve(_ decision: TodoGateDecision) {
        pendingPlan = nil
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

/// The data presented in the To-Do Gate card.
struct TodoGateRequest: Identifiable {
    let id = UUID()
    let goal: String
    let steps: [TodoGateStep]
    let modelName: String
}

struct TodoGateStep: Identifiable {
    let id: String
    let ordinal: Int
    let title: String
    let phase: String?
}

enum TodoGateDecision {
    case approved
    case refined(feedback: String)
    case rejected
}
