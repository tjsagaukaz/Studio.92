// ToolGuardrailsTests.swift
// Studio.92 — Agent Council Guardrails Tests

import Foundation
import XCTest
@testable import AgentCouncil

final class ToolGuardrailsTests: XCTestCase {

    // MARK: - Permission Policy: All Tools Allowed

    func testAllToolsAllowed() {
        let policy = ToolPermissionPolicy()
        for tool in ["file_write", "file_patch", "terminal", "deploy_to_testflight", "delegate_to_worktree", "file_read", "list_files", "web_search"] {
            XCTAssertEqual(policy.check(tool), .allowed, "\(tool) should be allowed")
        }
    }

    // MARK: - Permission Result

    func testPermissionResultReasonExtraction() {
        let blocked = PermissionResult.blocked(reason: "denied")
        XCTAssertEqual(blocked.reason, "denied")
        XCTAssertTrue(blocked.isBlocked)

        let allowed = PermissionResult.allowed
        XCTAssertNil(allowed.reason)
        XCTAssertFalse(allowed.isBlocked)
    }

    // MARK: - Sandbox Policy: Basic Path Checks

    func testSandboxAllowsPathInsideProject() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root)
        let url = root.appendingPathComponent("Sources/App.swift")
        XCTAssertTrue(sandbox.check(url))
    }

    func testSandboxDeniesPathOutsideProject() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root)
        let url = URL(fileURLWithPath: "/tmp/other/Secrets.swift")
        XCTAssertFalse(sandbox.check(url))
    }

    func testSandboxDeniesPathTraversal() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root)
        let url = root.appendingPathComponent("../other/Escape.swift")
        XCTAssertFalse(sandbox.check(url))
    }

    func testSandboxWithoutMachineAccessEnforcesBounds() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root, allowMachineWideAccess: false)
        let url = URL(fileURLWithPath: "/tmp/other/Secrets.swift")
        XCTAssertFalse(sandbox.check(url))
    }

    func testSandboxWithMachineAccessBypasses() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root, allowMachineWideAccess: true)
        let url = URL(fileURLWithPath: "/tmp/other/Anywhere.swift")
        XCTAssertTrue(sandbox.check(url))
    }

    // MARK: - Sandbox Policy: Symlink Escape

    func testSandboxRejectsSymlinkEscapeForExistingTarget() throws {
        let (tempRoot, projectRoot, outsideDir) = try makeSandboxFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create symlink inside project pointing to outside directory
        let symlinkURL = projectRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        // Write a file through the symlink so it exists on disk
        let escapedFile = outsideDir.appendingPathComponent("Escape.swift")
        try "struct Escape {}".write(to: escapedFile, atomically: true, encoding: .utf8)

        let sandbox = SandboxPolicy(projectRoot: projectRoot)
        let url = projectRoot.appendingPathComponent("linked/Escape.swift")
        XCTAssertFalse(sandbox.check(url), "Symlink escape through existing file should be denied")
    }

    func testSandboxRejectsSymlinkEscapeForNonExistentTarget() throws {
        let (tempRoot, projectRoot, outsideDir) = try makeSandboxFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create symlink inside project pointing to outside directory
        let symlinkURL = projectRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        // Target file doesn't exist yet (file_write scenario)
        let sandbox = SandboxPolicy(projectRoot: projectRoot)
        let url = projectRoot.appendingPathComponent("linked/NewFile.swift")
        XCTAssertFalse(sandbox.check(url), "Symlink escape through non-existent file should be denied")
    }

    func testSandboxAllowsLegitimateSymlinkInsideProject() throws {
        let (tempRoot, projectRoot, _) = try makeSandboxFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Create a subdirectory and symlink to it from within the project
        let realDir = projectRoot.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkURL = projectRoot.appendingPathComponent("SourcesLink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realDir)

        let sandbox = SandboxPolicy(projectRoot: projectRoot)
        let url = projectRoot.appendingPathComponent("SourcesLink/App.swift")
        XCTAssertTrue(sandbox.check(url), "Symlink pointing within project should be allowed")
    }

    // MARK: - Sandbox Policy: resolvedURL

    func testResolvedURLRelativePath() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root)
        let url = sandbox.resolvedURL(for: "Sources/App.swift")
        XCTAssertEqual(url.path, "/tmp/project/Sources/App.swift")
    }

    func testResolvedURLAbsolutePath() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let sandbox = SandboxPolicy(projectRoot: root)
        let url = sandbox.resolvedURL(for: "/etc/passwd")
        XCTAssertEqual(url.path, "/etc/passwd")
    }

    // MARK: - Subagent Guardrails

    func testSubagentGuardrailsInheritSandbox() {
        let parentSandbox = SandboxPolicy(
            projectRoot: URL(fileURLWithPath: "/tmp/project"),
            allowMachineWideAccess: true
        )
        let guardrails = SubagentGuardrails.forSubagent(parentSandbox: parentSandbox)

        // Subagent should not get machine-wide access
        XCTAssertFalse(guardrails.sandbox.allowMachineWideAccess)
        // Subagent inherits parent's sandbox root
        XCTAssertEqual(guardrails.sandbox.projectRoot.path, "/tmp/project")
        // All tools allowed
        XCTAssertEqual(guardrails.permissions.check("file_write"), .allowed)
        XCTAssertEqual(guardrails.permissions.check("file_read"), .allowed)
    }

    // MARK: - Integration: ToolExecutor with Guardrails

    func testToolExecutorAllowsAllTools() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "write-test",
            name: "delegate_to_worktree",
            input: [:]
        )

        // delegate_to_worktree may fail for other reasons (not implemented, etc.)
        // but should NOT fail due to permission blocking
        if outcome.isError {
            XCTAssertFalse(outcome.displayText.contains("Permission blocked"))
        }
    }

    func testToolExecutorSymlinkEscapeBlocked() async throws {
        let (tempRoot, projectRoot, outsideDir) = try makeSandboxFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let symlinkURL = projectRoot.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        // Place a secret file outside the project, reachable only via the symlink
        let secretFile = outsideDir.appendingPathComponent("Secret.swift")
        try "top secret".write(to: secretFile, atomically: true, encoding: .utf8)

        // Use executor without machine-wide access — sandbox is the only gate
        let executor = ToolExecutor(projectRoot: projectRoot, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "symlink-escape",
            name: "file_read",
            input: [
                "path": .string("linked/Secret.swift")
            ]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("Access denied"),
                       "Symlink escape should be caught by sandbox, got: \(outcome.displayText)")
    }

    // MARK: - Helpers

    private func makeScratchDirectory() throws -> (base: URL, projectRoot: URL, outsideFile: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = base.appendingPathComponent("workspace", isDirectory: true)
        let outsideFile = base.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        return (base: base, projectRoot: projectRoot, outsideFile: outsideFile)
    }

    private func makeSandboxFixture() throws -> (tempRoot: URL, projectRoot: URL, outsideDir: URL) {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("project", isDirectory: true)
        let outsideDir = tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        return (tempRoot: tempRoot, projectRoot: projectRoot, outsideDir: outsideDir)
    }
}
