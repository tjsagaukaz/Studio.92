// AgentCouncilTests.swift
// Studio.92 — Agent Builder Tests

import Foundation
import XCTest
@testable import AgentCouncil

final class AgentCouncilTests: XCTestCase {

    func testBuilderSystemPromptIncludesCurrentOperatingRules() {
        let prompt = BuilderSystemPrompt.make(
            autonomyMode: .fullSend,
            projectRoot: URL(fileURLWithPath: "/tmp/studio92"),
            currentDate: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        )

        XCTAssertTrue(prompt.contains("web_search"))
        XCTAssertTrue(prompt.contains("Current mode: fullSend"))
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

    func testReviewModeDeniesWriteOutsideProjectRoot() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, autonomyMode: .review)
        let outcome = await executor.execute(
            toolCallID: "review-write",
            name: "file_write",
            input: [
                "path": .string(sandbox.outsideFile.path),
                "content": .string("hello")
            ]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("Review mode"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.outsideFile.path))
    }

    func testFullSendAllowsWriteOutsideProjectRoot() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, autonomyMode: .fullSend)
        let outcome = await executor.execute(
            toolCallID: "fullsend-write",
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

    func testPlanModeBlocksDeploymentTool() async throws {
        let sandbox = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox.base) }

        let executor = ToolExecutor(projectRoot: sandbox.projectRoot, autonomyMode: .plan)
        let outcome = await executor.execute(
            toolCallID: "plan-deploy",
            name: "deploy_to_testflight",
            input: [:]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("Plan mode"))
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
