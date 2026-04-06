// ExecutorTests.swift
// Studio.92 — Executor Tests

import XCTest
@testable import Executor

final class ExecutorTests: XCTestCase {

    // MARK: - Error Path Parsing

    func testParseErrorPaths_deduplicates() async {
        let errors = """
        /Users/tj/Desktop/Studio.92/Sources/MyApp/ContentView.swift:12:5: error: cannot find 'Foo' in scope
        /Users/tj/Desktop/Studio.92/Sources/MyApp/ContentView.swift:15:10: error: type 'Bar' has no member 'baz'
        /Users/tj/Desktop/Studio.92/Sources/MyApp/Models.swift:3:1: error: expected declaration
        /Users/tj/Desktop/Studio.92/Sources/MyApp/ContentView.swift:20:8: error: missing return in function
        """

        let config = ExecutorConfig(projectRoot: "/tmp")
        let api = OpenAIAPIClient(apiKey: "test-key")
        let agent = ExecutorAgent(api: api, config: config)

        let paths = await agent.parseErrorPaths(from: errors)

        // Should be exactly 2 unique paths, sorted
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0], "/Users/tj/Desktop/Studio.92/Sources/MyApp/ContentView.swift")
        XCTAssertEqual(paths[1], "/Users/tj/Desktop/Studio.92/Sources/MyApp/Models.swift")
    }

    func testParseErrorPaths_ignoresWarnings() async {
        let errors = """
        /path/File.swift:10:5: warning: unused variable
        /path/File.swift:12:5: error: cannot find type 'Foo'
        """

        let config = ExecutorConfig(projectRoot: "/tmp")
        let api = OpenAIAPIClient(apiKey: "test-key")
        let agent = ExecutorAgent(api: api, config: config)

        let paths = await agent.parseErrorPaths(from: errors)

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths[0], "/path/File.swift")
    }

    func testParseErrorPaths_emptyInput() async {
        let config = ExecutorConfig(projectRoot: "/tmp")
        let api = OpenAIAPIClient(apiKey: "test-key")
        let agent = ExecutorAgent(api: api, config: config)

        let paths = await agent.parseErrorPaths(from: "")

        XCTAssertTrue(paths.isEmpty)
    }

    // MARK: - Fix Validation

    func testFixResponseGuardrails_acceptValidFixes() throws {
        let response = FixResponse(version: 1, fixes: [
            FileFix(
                filePath: " Sources/App/View.swift \n",
                content: "import SwiftUI\nstruct ViewA {}"
            )
        ])

        let validated = try FixResponseGuardrails.validate(
            response,
            projectRoot: "/tmp/project"
        )

        XCTAssertEqual(validated.fixes.count, 1)
        XCTAssertEqual(validated.version, 1)
        XCTAssertEqual(validated.fixes[0].id, "fix_1")
        XCTAssertEqual(validated.fixes[0].filePath, "Sources/App/View.swift")
    }

    func testFixResponseGuardrails_preservesExplicitFixID() throws {
        let response = FixResponse(version: 1, fixes: [
            FileFix(
                id: "view_fix",
                filePath: "Sources/App/View.swift",
                content: "import SwiftUI\nstruct ViewA {}"
            )
        ])

        let validated = try FixResponseGuardrails.validate(
            response,
            projectRoot: "/tmp/project"
        )

        XCTAssertEqual(validated.fixes[0].id, "view_fix")
    }

    func testFixResponseGuardrails_rejectUnsupportedSchemaVersion() {
        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                FixResponse(version: 2, fixes: [
                    FileFix(filePath: "Sources/App/View.swift", content: "struct ViewA {}")
                ]),
                projectRoot: "/tmp/project"
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.unsupportedSchemaVersion(expected: 1, actual: 2))
            )
        }
    }

    func testFixResponseGuardrails_rejectEmptyFixes() {
        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                FixResponse(version: 1, fixes: []),
                projectRoot: "/tmp/project"
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.emptyFixes)
            )
        }
    }

    func testFixResponseGuardrails_rejectDuplicateResolvedPaths() {
        let response = FixResponse(version: 1, fixes: [
            FileFix(filePath: "Sources/App/View.swift", content: "struct A {}"),
            FileFix(filePath: "/tmp/project/Sources/App/View.swift", content: "struct B {}")
        ])

        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                response,
                projectRoot: "/tmp/project"
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.duplicateFixPath(path: "/tmp/project/Sources/App/View.swift"))
            )
        }
    }

    func testFixResponseGuardrails_rejectPathTraversalOutsideProjectRoot() {
        let response = FixResponse(version: 1, fixes: [
            FileFix(filePath: "../Secrets.swift", content: "let token = \"nope\"")
        ])

        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                response,
                projectRoot: "/tmp/project"
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.pathOutsideProjectRoot(path: "../Secrets.swift"))
            )
        }
    }

    func testFixResponseGuardrails_rejectSymlinkEscape() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectRoot = tempRoot.appendingPathComponent("project")
        let outsideRoot = tempRoot.appendingPathComponent("outside")
        let symlinkURL = projectRoot.appendingPathComponent("linked")

        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideRoot)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let response = FixResponse(version: 1, fixes: [
            FileFix(filePath: "linked/Escape.swift", content: "struct Escape {}")
        ])

        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                response,
                projectRoot: projectRoot.path
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.pathOutsideProjectRoot(path: "linked/Escape.swift"))
            )
        }
    }

    func testFixResponseGuardrails_rejectBlankContent() {
        let response = FixResponse(version: 1, fixes: [
            FileFix(filePath: "Sources/App/View.swift", content: "   \n")
        ])

        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                response,
                projectRoot: "/tmp/project"
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.emptyFixContent(path: "Sources/App/View.swift"))
            )
        }
    }

    func testFixResponseGuardrails_rejectTooManyFixes() {
        let fixes = (1...21).map { index in
            FileFix(
                id: "fix_\(index)",
                filePath: "Sources/App/File\(index).swift",
                content: "struct File\(index) {}"
            )
        }

        XCTAssertThrowsError(
            try FixResponseGuardrails.validate(
                FixResponse(version: 1, fixes: fixes),
                projectRoot: "/tmp/project",
                maxFixCount: 20
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                String(describing: ExecutorError.tooManyFixes(count: 21, max: 20))
            )
        }
    }

    func testFixResponseGuardrails_validationResult_collectsMultipleFailures() {
        let response = FixResponse(version: 2, fixes: [
            FileFix(filePath: "../Secrets.swift", content: "   \n"),
            FileFix(filePath: "/tmp/project/Sources/App/View.swift", content: "struct A {}"),
            FileFix(filePath: "Sources/App/View.swift", content: "struct B {}")
        ])

        let result = FixResponseGuardrails.validationResult(
            for: response,
            projectRoot: "/tmp/project"
        )

        XCTAssertNil(result.response)
        XCTAssertEqual(
            result.failures.map(\.type),
            ["unsupported_schema_version", "empty_content", "out_of_root", "duplicate_path"]
        )
    }

    func testExecutorError_validationFailed_usesFailureMessages() {
        let error = ExecutorError.validationFailed(
            failures: [
                ValidationFailure(type: "duplicate_path", message: "Duplicate path detected: View.swift"),
                ValidationFailure(type: "out_of_root", message: "File path is outside the project root: ../Secrets.swift")
            ]
        )

        XCTAssertEqual(
            String(describing: error),
            "Structured fix response failed validation: Duplicate path detected: View.swift; File path is outside the project root: ../Secrets.swift"
        )
    }

    // MARK: - OpenAI Request Encoding

    func testOpenAIRequest_encoding() throws {
        let request = OpenAIRequest(
            model:    "gpt-4.5-preview",
            messages: [.system("You are helpful"), .user("Fix this")],
            maxTokens: 2048,
            temperature: 0.1
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]


        // Verify snake_case keys
        XCTAssertEqual(dict["model"] as? String, "gpt-4.5-preview")
        XCTAssertEqual(dict["max_tokens"] as? Int, 2048)
        XCTAssertEqual(dict["temperature"] as? Double, 0.1)
        XCTAssertNotNil(dict["messages"])
        XCTAssertNotNil(dict["response_format"])

        let format = dict["response_format"] as? [String: String]
        XCTAssertEqual(format?["type"], "json_object")
    }

    // MARK: - OpenAI Response Decoding

    func testOpenAIResponse_decoding() throws {
        let json = """
        {
          "id": "chatcmpl-123",
          "choices": [
            {
              "index": 0,
              "message": {
                "role": "assistant",
                "content": "{ \\"fixes\\": [] }"
              },
              "finish_reason": "stop"
            }
          ],
          "model": "gpt-4.5-preview",
          "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "total_tokens": 150
          }
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)

        XCTAssertEqual(response.id, "chatcmpl-123")
        XCTAssertEqual(response.model, "gpt-4.5-preview")
        XCTAssertEqual(response.text, "{ \"fixes\": [] }")
        XCTAssertEqual(response.usage.total_tokens, 150)
    }

    // MARK: - ExecutorResult Round-trip

    func testExecutorResult_roundTrip() throws {
        let result = ExecutorResult(
            status: .fixed,
            attemptsUsed: 2,
            filesModified: ["A.swift", "B.swift"],
            finalBuildOutput: "Build succeeded"
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ExecutorResult.self, from: data)

        XCTAssertEqual(decoded.status, .fixed)
        XCTAssertEqual(decoded.attemptsUsed, 2)
        XCTAssertEqual(decoded.filesModified, ["A.swift", "B.swift"])
        XCTAssertEqual(decoded.finalBuildOutput, "Build succeeded")
        XCTAssertFalse(decoded.timestamp.isEmpty)
    }
}
