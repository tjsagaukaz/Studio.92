// ToolGuardrails.swift
// Studio.92 — Agent Council
// Single source of truth for tool permission and sandbox policies.
// Both SPM (ToolExecutor) and CommandCenter (AgenticClient) depend on these
// concrete types instead of maintaining separate inline checks.

import Foundation

// MARK: - Tool Permission Policy

public struct ToolPermissionPolicy: Sendable {

    public let blockedTools: Set<String>

    public init(blockedTools: Set<String> = []) {
        self.blockedTools = blockedTools
    }

    public func check(_ toolName: String) -> PermissionResult {
        if blockedTools.contains(toolName) {
            return .blocked(reason: "\(toolName) is disabled by policy")
        }
        return .allowed
    }
}

public enum PermissionResult: Sendable, Equatable {
    case allowed
    case blocked(reason: String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var reason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Sandbox Policy

public struct SandboxPolicy: Sendable {

    public let projectRoot: URL
    public let allowMachineWideAccess: Bool

    public init(projectRoot: URL, allowMachineWideAccess: Bool = false) {
        self.projectRoot = projectRoot
        self.allowMachineWideAccess = allowMachineWideAccess
    }

    public func check(_ url: URL) -> Bool {
        if allowMachineWideAccess {
            return true
        }
        let path = url.path
        if path.contains("\0") { return false }
        if path.split(separator: "/").contains("..") { return false }
        let resolved = resolveSymlinks(url)
        let root = resolveSymlinks(projectRoot)
        return resolved.hasPrefix(root + "/") || resolved == root
    }

    public func resolvedURL(for path: String) -> URL {
        if path.contains("\0") {
            return projectRoot
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
    }

    /// Resolve symlinks defensively using realpath(3), walking up to the
    /// nearest existing ancestor when the leaf or intermediate dirs don't
    /// exist yet (e.g. file_write creating a new file). This ensures
    /// intermediate symlinks (like /tmp → /private/tmp) are always resolved
    /// consistently, preventing sandbox escape.
    private func resolveSymlinks(_ url: URL) -> String {
        let path = url.path
        if let real = realpath(path, nil) {
            let resolved = String(cString: real)
            free(real)
            return resolved
        }
        // Walk up until we find an ancestor that exists on disk,
        // resolve it with realpath, then re-append the trailing components.
        var current = url.standardized
        var trailing: [String] = []
        while current.path != "/" {
            trailing.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
            if let real = realpath(current.path, nil) {
                let base = String(cString: real)
                free(real)
                var result = base
                for component in trailing.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
        }
        // Absolute fallback — no ancestor resolved via realpath.
        return url.resolvingSymlinksInPath().standardized.path
    }
}

// MARK: - Subagent Guardrails

public struct SubagentGuardrails: Sendable {
    public let sandbox: SandboxPolicy
    public let permissions: ToolPermissionPolicy

    public init(sandbox: SandboxPolicy, permissions: ToolPermissionPolicy) {
        self.sandbox = sandbox
        self.permissions = permissions
    }

    /// Build guardrails for a subagent that inherits the parent's sandbox.
    public static func forSubagent(
        parentSandbox: SandboxPolicy
    ) -> SubagentGuardrails {
        SubagentGuardrails(
            sandbox: SandboxPolicy(
                projectRoot: parentSandbox.projectRoot,
                allowMachineWideAccess: false
            ),
            permissions: ToolPermissionPolicy()
        )
    }
}
