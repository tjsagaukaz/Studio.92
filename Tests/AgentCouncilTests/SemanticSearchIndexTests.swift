import Foundation
import XCTest
@testable import AgentCouncil

final class SemanticSearchIndexTests: XCTestCase {

    func testStructuredChunkerProducesStableChunkIDsAcrossBodyEdits() {
        let original = """
        struct Example {
            func render() {
                print("first")
            }
        }
        """
        let edited = """
        struct Example {
            func render() {
                print("second")
            }
        }
        """

        let originalChunks = SwiftStructuredChunker.chunkFile(path: "Sources/Example.swift", source: original)
        let editedChunks = SwiftStructuredChunker.chunkFile(path: "Sources/Example.swift", source: edited)

        let originalFunction = originalChunks.first { $0.summary == "func Example.render" }
        let editedFunction = editedChunks.first { $0.summary == "func Example.render" }

        XCTAssertNotNil(originalFunction)
        XCTAssertNotNil(editedFunction)
        XCTAssertEqual(originalFunction?.chunkID, editedFunction?.chunkID)
        XCTAssertNotEqual(originalFunction?.chunkHash, editedFunction?.chunkHash)
    }

    func testSemanticSearchReturnsRankedChunksAndPathFilters() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        try write(
            """
            struct PipelineRunner {
                func runStreamingPipeline() {
                    print("streaming pipeline orchestration")
                }
            }
            """,
            to: fixture.root.appendingPathComponent("CommandCenter/Execution/PipelineRunner.swift")
        )
        try write(
            """
            struct RepositoryMonitor {
                func refreshStatus() {
                    print("pipeline monitor")
                }
            }
            """,
            to: fixture.root.appendingPathComponent("CommandCenter/Workspace/RepositoryMonitor.swift")
        )

        let index = SemanticSearchIndex(projectRoot: fixture.root)
        let broad = try await index.search(request: SemanticSearchRequest(query: "streaming pipeline orchestration", maxResults: 5))

        XCTAssertEqual(broad.totalMatches, 2)
        XCTAssertEqual(broad.returnedMatches, 2)
        XCTAssertEqual(broad.matches.first?.path, "CommandCenter/Execution/PipelineRunner.swift")
        XCTAssertEqual(broad.matches.first?.startLine, 1)
        XCTAssertTrue(broad.matches.first?.summary.contains("PipelineRunner") == true)
        XCTAssertTrue(broad.matches.first?.snippet.contains("streaming pipeline orchestration") == true)

        let filtered = try await index.search(
            request: SemanticSearchRequest(
                query: "streaming pipeline orchestration",
                maxResults: 5,
                paths: [fixture.root.appendingPathComponent("CommandCenter/Workspace")]
            )
        )

        XCTAssertEqual(filtered.totalMatches, 1)
        XCTAssertEqual(filtered.returnedMatches, 1)
        XCTAssertEqual(filtered.matches.first?.path, "CommandCenter/Workspace/RepositoryMonitor.swift")
    }

    func testToolExecutorExecutesCanonicalSemanticSearch() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        try write(
            """
            extension TaskPlanEngine {
                func analyzePlanGraph() {
                    print("plan adaptation policy")
                }
            }
            """,
            to: fixture.root.appendingPathComponent("CommandCenter/Routing/TaskPlanEngine.swift")
        )

        let executor = ToolExecutor(projectRoot: fixture.root, allowMachineWideAccess: false)
        let outcome = await executor.execute(
            toolCallID: "semantic-1",
            name: "semantic_search",
            input: [
                "query": .string("plan adaptation policy"),
                "max_results": .int(3)
            ]
        )

        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.displayText.contains("semantic matches"))
        switch outcome.toolResultContent {
        case .text(let payload):
            let result = try JSONDecoder().decode(SemanticSearchResult.self, from: Data(payload.utf8))
            XCTAssertEqual(result.totalMatches, 1)
            XCTAssertEqual(result.returnedMatches, 1)
            XCTAssertEqual(result.matches.first?.path, "CommandCenter/Routing/TaskPlanEngine.swift")
        case .blocks:
            XCTFail("Expected semantic_search to return text payload")
        }
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeWorkspace() throws -> (base: URL, root: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root)
    }
}