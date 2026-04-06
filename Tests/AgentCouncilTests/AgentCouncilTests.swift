// AgentCouncilTests.swift
// Studio.92 — Agent Builder Tests

import Foundation
import XCTest
@testable import AgentCouncil

final class AgentCouncilTests: XCTestCase {

    func testBuilderSystemPromptIncludesCurrentOperatingRules() {
        let prompt = BuilderSystemPrompt.make(
            projectRoot: URL(fileURLWithPath: "/tmp/studio92"),
            currentDate: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        )

        XCTAssertTrue(prompt.contains("web_search"))
        XCTAssertTrue(prompt.contains("full autonomy"))
        XCTAssertTrue(prompt.contains("/tmp/studio92"))
        XCTAssertTrue(prompt.contains("1970-01-01T00:00:00Z"))
    }

    func testAgentToolsExposeCoreBuilderWorkflow() {
        let names = Set(AgentTools.all.map(\.name))

        XCTAssertTrue(names.contains("file_read"))
        XCTAssertTrue(names.contains("file_write"))
        XCTAssertTrue(names.contains("file_patch"))
        XCTAssertTrue(names.contains("terminal"))
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("deploy_to_testflight"))
    }

    func testSandboxDeniesWriteOutsideProjectRoot() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "write-outside",
            name: "file_write",
            input: [
                "path": .string(sandbox.outsideFile.path),
                "content": .string("hello")
            ]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("Access denied") || outcome.displayText.contains("Sandbox"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.outsideFile.path))
    }

    func testMachineWideAccessAllowsWriteOutsideProjectRoot() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, allowMachineWideAccess: true)
        let outcome = await executor.execute(
            toolCallID: "write-outside",
            name: "file_write",
            input: [
                "path": .string(sandbox.outsideFile.path),
                "content": .string("hello")
            ]
        )

        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(
            try String(contentsOf: sandbox.outsideFile, encoding: .utf8),
            "hello"
        )
    }

    func testWithoutMachineAccessBlocksDeploymentTool() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        // deploy_to_testflight is always allowed by permission policy,
        // but may fail for other reasons (not blocked by mode)
        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "deploy",
            name: "deploy_to_testflight",
            input: [:]
        )

        // Should not be blocked by permissions (no modes anymore)
        XCTAssertFalse(outcome.displayText.contains("Permission blocked"))
    }

    func testTokenEstimationIsNonZero() {
        XCTAssertGreaterThan(ClaudeAPIClient.estimatedTokens(for: "Build an iOS app."), 0)
    }

    private func makeScratchDirectory() throws -> (base: URL, projectRoot: URL, outsideFile: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = base.appendingPathComponent("workspace", isDirectory: true)
        let outsideFile = base.appendingPathComponent("outside.txt")

        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        return (base: base, projectRoot: projectRoot, outsideFile: outsideFile)
    }
}

// MARK: - AGENTSParser Tests

final class AGENTSParserTests: XCTestCase {

    // MARK: - Round-Trip Parsing

    func testParseRealAGENTSMarkdown() {
        let markdown = """
        # Studio.92 Agents

        ## Model Roles

        - `Plan` and `Review`: `Claude Sonnet 4.6`
        - `Full Send`: `GPT-5.4`
        - `Subagents` and background worktrees: `GPT-5.4 mini`
        - `Release / Compliance`: `GPT-5.4`
        - `Escalation only`: `Claude Opus 4.6`

        ## Operating Rules

        - Treat Git as the source of truth.
        - Prefer SwiftUI and native Apple frameworks.
        - Build and verify real code.

        ## Workspace Conventions

        - Background sessions live in `.studio92/sessions/`
        - Isolated worktrees live in `.studio92/worktrees/`
        """
        let manifest = AGENTSParser.parse(markdown: markdown)

        XCTAssertEqual(manifest.operatingRules.count, 3)
        XCTAssertTrue(manifest.operatingRules[0].contains("Git"))
        XCTAssertTrue(manifest.operatingRules[1].contains("SwiftUI"))
        XCTAssertTrue(manifest.operatingRules[2].contains("verify real code"))

        XCTAssertEqual(manifest.modelRoles["plan"], "Claude Sonnet 4.6")
        XCTAssertEqual(manifest.modelRoles["review"], "Claude Sonnet 4.6")
        XCTAssertEqual(manifest.modelRoles["full send"], "GPT-5.4")
        XCTAssertEqual(manifest.modelRoles["subagents"], "GPT-5.4 mini")
        XCTAssertEqual(manifest.modelRoles["escalation only"], "Claude Opus 4.6")

        XCTAssertEqual(manifest.workspaceConventions["background sessions"], ".studio92/sessions/")
        XCTAssertEqual(manifest.workspaceConventions["isolated worktrees"], ".studio92/worktrees/")
    }

    // MARK: - Fuzzy Header Matching

    func testCaseInsensitiveHeaders() {
        let markdown = """
        ## OPERATING RULES

        - Rule one.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 1)
        XCTAssertTrue(manifest.operatingRules[0].contains("Rule one"))
    }

    func testTripleHashHeaders() {
        let markdown = """
        ### Operating Rules

        - Deeply nested rule.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 1)
    }

    // MARK: - Bullet Format Tolerance

    func testAsteriskBullets() {
        let markdown = """
        ## Operating Rules

        * Rule with asterisk.
        * Another asterisk rule.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 2)
        XCTAssertTrue(manifest.operatingRules[0].contains("asterisk"))
    }

    func testNumberedList() {
        let markdown = """
        ## Operating Rules

        1. First rule.
        2. Second rule.
        3. Third rule.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 3)
        XCTAssertEqual(manifest.operatingRules[0], "First rule.")
    }

    func testMultiLineBullet() {
        let markdown = """
        ## Operating Rules

        - This is a rule that spans
          multiple lines of text.
        - Second rule.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 2)
        XCTAssertTrue(manifest.operatingRules[0].contains("spans multiple lines"))
    }

    // MARK: - Model Role Extraction

    func testAndSplitsIntoSeparateRoles() {
        let markdown = """
        ## Model Roles

        - `Plan` and `Review`: `Claude Sonnet 4.6`
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.modelRoles["plan"], "Claude Sonnet 4.6")
        XCTAssertEqual(manifest.modelRoles["review"], "Claude Sonnet 4.6")
    }

    func testTrailingQualifierStripped() {
        let markdown = """
        ## Model Roles

        - `Standards Research`: `GPT-5.4 mini`, escalate to GPT-5.4 when sources conflict
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.modelRoles["standards research"], "GPT-5.4 mini")
    }

    func testBackticksStripped() {
        let markdown = """
        ## Model Roles

        - `Full Send`: `GPT-5.4`
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.modelRoles["full send"], "GPT-5.4")
    }

    // MARK: - Missing / Malformed Content

    func testEmptyMarkdownReturnsEmptyManifest() {
        let manifest = AGENTSParser.parse(markdown: "")
        XCTAssertTrue(manifest.isEmpty)
    }

    func testMarkdownWithNoSectionsReturnsEmptyManifest() {
        let markdown = "# Just a Title\n\nSome paragraph text."
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertTrue(manifest.isEmpty)
    }

    func testMissingSectionReturnsPartialManifest() {
        let markdown = """
        ## Operating Rules

        - Only rule.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 1)
        XCTAssertTrue(manifest.modelRoles.isEmpty)
        XCTAssertTrue(manifest.workspaceConventions.isEmpty)
        XCTAssertFalse(manifest.isEmpty)
    }

    func testMissingFileReturnsEmptyManifest() {
        let manifest = AGENTSParser.parse(projectRoot: URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)"))
        XCTAssertTrue(manifest.isEmpty)
    }

    // MARK: - Workspace Convention Extraction

    func testWorkspaceConventionParsing() {
        let markdown = """
        ## Workspace Conventions

        - Background sessions live in `.studio92/sessions/`
        - Apple shipping defaults live in `.studio92/ship.toml`
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.workspaceConventions["background sessions"], ".studio92/sessions/")
        XCTAssertEqual(manifest.workspaceConventions["apple shipping defaults"], ".studio92/ship.toml")
    }

    // MARK: - Section Boundary (EOF)

    func testLastSectionExtendedToEOF() {
        let markdown = """
        ## Operating Rules

        - Rule that continues to end of file without another section.
        """
        let manifest = AGENTSParser.parse(markdown: markdown)
        XCTAssertEqual(manifest.operatingRules.count, 1)
    }
}
