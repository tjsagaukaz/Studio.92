import Foundation
import XCTest
@testable import AgentCouncil

final class ExactSearchEngineTests: XCTestCase {

    private let decoder = JSONDecoder()

    func testExactSearchReturnsDeterministicMatchesWithContext() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let appFile = fixture.root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        struct Example {
            let value = "needle"
            func render() {
                print("needle")
            }
        }
        """.write(to: appFile, atomically: true, encoding: .utf8)

        let request = ExactSearchRequest(
            query: "needle",
            isRegexp: false,
            caseSensitive: true,
            maxResults: 10,
            contextLines: 1
        )

        let result = try await ExactSearchEngine.search(request: request, projectRoot: fixture.root)

        XCTAssertEqual(result.totalMatches, 2)
        XCTAssertEqual(result.returnedMatches, 2)
        XCTAssertGreaterThanOrEqual(result.queryTimeMs, 0)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(result.matches[0].path, "Sources/App.swift")
        XCTAssertEqual(result.matches[0].line, 2)
        XCTAssertTrue(result.matches[0].column > 0)
        XCTAssertEqual(result.matches[0].before, ["struct Example {"])
        XCTAssertEqual(result.matches[0].after, ["    func render() {"])
        XCTAssertEqual(result.matches[1].line, 4)
    }

    func testExactSearchSortsByPathLineAndColumnAndCountsOccurrences() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let aFile = fixture.root.appendingPathComponent("A.swift")
        let bFile = fixture.root.appendingPathComponent("B.swift")
        try "let tokens = \"needle needle\"\n".write(to: aFile, atomically: true, encoding: .utf8)
        try "let token = \"needle\"\n".write(to: bFile, atomically: true, encoding: .utf8)

        let result = try await ExactSearchEngine.search(
            request: ExactSearchRequest(query: "needle", caseSensitive: true),
            projectRoot: fixture.root
        )

        XCTAssertEqual(result.totalMatches, 3)
        XCTAssertEqual(result.returnedMatches, 3)
        XCTAssertEqual(result.matches.map(\.path), ["A.swift", "A.swift", "B.swift"])
        XCTAssertEqual(result.matches.map(\.line), [1, 1, 1])
        XCTAssertLessThan(result.matches[0].column, result.matches[1].column)
        XCTAssertLessThan(result.matches[1].path, result.matches[2].path)
    }

    func testToolExecutorExecutesCanonicalGrepSearchWithStructuredMetadata() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let appFile = fixture.root.appendingPathComponent("main.swift")
        try """
        let first = "search-target"
        let second = "search-target"
        """.write(to: appFile, atomically: true, encoding: .utf8)

        let executor = ToolExecutor(projectRoot: fixture.root, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "grep-1",
            name: "grep_search",
            input: [
                "query": .string("search-target"),
                "max_results": .int(1)
            ]
        )

        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("Found 1 of 2 matches"))
        XCTAssertTrue(outcome.displayText.contains("[Truncated]"))
        switch outcome.toolResultContent {
        case .text(let payload):
            let result = try decoder.decode(ExactSearchResult.self, from: Data(payload.utf8))
            XCTAssertEqual(result.totalMatches, 2)
            XCTAssertEqual(result.returnedMatches, 1)
            XCTAssertTrue(result.truncated)
            XCTAssertGreaterThanOrEqual(result.queryTimeMs, 0)
            XCTAssertEqual(result.matches.count, 1)
            XCTAssertEqual(result.matches[0].path, "main.swift")
            XCTAssertTrue(result.matches[0].lineText.contains("search-target"))
        case .blocks:
            XCTFail("Expected grep_search to return text payload")
        }
    }

    private func makeWorkspace() throws -> (base: URL, root: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }
}