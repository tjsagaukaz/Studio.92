// BuildDiagnosticsTests.swift
// Studio.92 — Golden-fixture tests for structured build/test failure extraction.

import Foundation
import XCTest
@testable import BuildDiagnostics

final class BuildDiagnosticsTests: XCTestCase {

    // MARK: - Command Detection

    func testDetectsSwiftBuild() {
        XCTAssertEqual(BuildCommandKind(command: "swift build"), .swiftBuild)
        XCTAssertEqual(BuildCommandKind(command: "swift build -c release"), .swiftBuild)
        XCTAssertEqual(BuildCommandKind(command: "cd /foo && swift build 2>&1 | tail -10"), .swiftBuild)
    }

    func testDetectsSwiftTest() {
        XCTAssertEqual(BuildCommandKind(command: "swift test"), .swiftTest)
        XCTAssertEqual(BuildCommandKind(command: "swift test 2>&1 | tail -15"), .swiftTest)
        XCTAssertEqual(BuildCommandKind(command: "cd /project && swift test --filter Foo"), .swiftTest)
    }

    func testDetectsXcodebuild() {
        XCTAssertEqual(BuildCommandKind(command: "xcodebuild -project Foo.xcodeproj -scheme Foo build"), .xcodebuild)
        XCTAssertEqual(BuildCommandKind(command: "cd /project && xcodebuild build 2>&1 | tail -25"), .xcodebuild)
    }

    func testDoesNotDetectUnrelatedCommand() {
        XCTAssertNil(BuildCommandKind(command: "ls -la"))
        XCTAssertNil(BuildCommandKind(command: "cat foo.swift"))
        XCTAssertNil(BuildCommandKind(command: "git status"))
    }

    // MARK: - Swift Build Parser: Compile Error

    func testSwiftBuildCompileError() {
        let output = """
        Building for debugging...
        /Users/tj/Project/Sources/Foo.swift:42:13: error: value of type 'String' has no member 'count2'
        /Users/tj/Project/Sources/Foo.swift:42:13: note: did you mean 'count'?
        Build complete! (failed)
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertEqual(issues.count, 2)

        let error = issues[0]
        XCTAssertEqual(error.severity, .error)
        XCTAssertEqual(error.source, .swiftBuild)
        XCTAssertTrue(error.file?.hasSuffix("Foo.swift") ?? false)
        XCTAssertEqual(error.line, 42)
        XCTAssertEqual(error.column, 13)
        XCTAssertEqual(error.message, "value of type 'String' has no member 'count2'")

        let note = issues[1]
        XCTAssertEqual(note.severity, .note)
    }

    func testSwiftBuildWarning() {
        let output = """
        Building for debugging...
        /Users/tj/Project/Sources/Bar.swift:10:5: warning: variable 'x' was never used; consider replacing with '_' or removing it
        Build complete!
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertEqual(issues[0].line, 10)
        XCTAssertTrue(issues[0].message.contains("variable 'x' was never used"))
    }

    func testSwiftBuildLinkerError() {
        let output = """
        Building for debugging...
        ld: symbol(s) not found for architecture arm64
        clang: error: linker command failed with exit code 1 (use -v to see invocation)
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertTrue(issues.count >= 2)

        let linkerIssues = issues.filter { $0.message.contains("symbol(s) not found") || $0.message.contains("linker command failed") }
        XCTAssertFalse(linkerIssues.isEmpty)
        XCTAssertTrue(linkerIssues.allSatisfy { $0.severity == .error })
    }

    func testSwiftBuildBareError() {
        let output = """
        error: no such module 'FooKit'
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .error)
        XCTAssertEqual(issues[0].message, "no such module 'FooKit'")
        XCTAssertNil(issues[0].file)
    }

    func testSwiftBuildCleanOutput() {
        let output = """
        Building for debugging...
        Build complete! (0.74s)
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Swift Test Parser: XCTest Failure

    func testSwiftTestXCTestFailure() {
        let output = """
        Test Suite 'All tests' started at 2024-01-15 10:30:00.000.
        Test Suite 'AgentCouncilTests' started at 2024-01-15 10:30:00.001.
        Test Case '-[AgentCouncilTests.ConversationStoreTests testThreadContinuity]' started.
        /Users/tj/Project/Tests/AgentCouncilTests/ConversationStoreTests.swift:118: error: -[AgentCouncilTests.ConversationStoreTests testThreadContinuity] : XCTAssertEqual failed: ("hello") is not equal to ("world")
        Test Case '-[AgentCouncilTests.ConversationStoreTests testThreadContinuity]' failed (0.003 seconds).
        Test Suite 'ConversationStoreTests' failed at 2024-01-15 10:30:00.004.
        Executed 1 test, with 1 failure (0 unexpected) in 0.003 (0.004) seconds
        """

        let (issues, failures) = SwiftTestParser.parse(output)

        XCTAssertEqual(failures.count, 1)
        let failure = failures[0]
        XCTAssertEqual(failure.suite, "AgentCouncilTests.ConversationStoreTests")
        XCTAssertEqual(failure.testCase, "testThreadContinuity")
        XCTAssertTrue(failure.message.contains("XCTAssertEqual failed"))
        XCTAssertTrue(failure.file?.hasSuffix("ConversationStoreTests.swift") ?? false)
        XCTAssertEqual(failure.line, 118)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .error)
        XCTAssertEqual(issues[0].source, .swiftTest)
        XCTAssertTrue(issues[0].testName?.contains("testThreadContinuity") ?? false)
    }

    func testSwiftTestCompileError() {
        let output = """
        Building for testing...
        /Users/tj/Project/Tests/FooTests/FooTests.swift:5:10: error: cannot find 'FooManager' in scope
        Build complete! (failed)
        """

        let (issues, failures) = SwiftTestParser.parse(output)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .error)
        XCTAssertEqual(issues[0].source, .swiftTest)
        XCTAssertEqual(issues[0].message, "cannot find 'FooManager' in scope")
        XCTAssertTrue(failures.isEmpty) // It's a compile error, not a test failure
    }

    func testSwiftTestMultipleFailures() {
        let output = """
        /Users/tj/Project/Tests/FooTests.swift:10: error: -[FooTests testA] : XCTAssertTrue failed
        /Users/tj/Project/Tests/FooTests.swift:20: error: -[FooTests testB] : XCTAssertEqual failed: ("1") is not equal to ("2")
        Executed 5 tests, with 2 failures (0 unexpected) in 0.010 (0.011) seconds
        """

        let (issues, failures) = SwiftTestParser.parse(output)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures[0].testCase, "testA")
        XCTAssertEqual(failures[1].testCase, "testB")
        XCTAssertEqual(issues.count, 2)
    }

    func testSwiftTestAllPassing() {
        let output = """
        Test Suite 'All tests' started at 2024-01-15 10:30:00.000.
        Test Suite 'All tests' passed at 2024-01-15 10:30:01.000.
        Executed 78 tests, with 0 failures (0 unexpected) in 1.000 (1.001) seconds
        """

        let (issues, failures) = SwiftTestParser.parse(output)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    // MARK: - Xcodebuild Parser: Compile Error

    func testXcodebuildCompileError() {
        let output = """
        CompileSwift normal arm64 /Users/tj/Project/CommandCenter/PipelineRunner.swift (in target 'CommandCenter' from project 'CommandCenter')
        /Users/tj/Project/CommandCenter/PipelineRunner.swift:842:30: error: actor-isolated property 'state' can not be referenced from a nonisolated context
        /Users/tj/Project/CommandCenter/PipelineRunner.swift:842:30: note: property declared here
        ** BUILD FAILED **
        """

        let (issues, failures, succeeded) = XcodebuildParser.parse(output)

        XCTAssertEqual(succeeded, false)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(issues.count, 2)

        let error = issues[0]
        XCTAssertEqual(error.severity, .error)
        XCTAssertEqual(error.source, .xcodebuild)
        XCTAssertTrue(error.file?.hasSuffix("PipelineRunner.swift") ?? false)
        XCTAssertEqual(error.line, 842)
        XCTAssertEqual(error.column, 30)
        XCTAssertEqual(error.target, "CommandCenter")
        XCTAssertTrue(error.message.contains("actor-isolated property"))

        let note = issues[1]
        XCTAssertEqual(note.severity, .note)
    }

    func testXcodebuildBuildSucceeded() {
        let output = """
        CompileSwift normal arm64 /Users/tj/Project/CommandCenter/Foo.swift (in target 'CommandCenter' from project 'CommandCenter')
        Linking CommandCenter
        ** BUILD SUCCEEDED **
        """

        let (issues, _, succeeded) = XcodebuildParser.parse(output)
        XCTAssertEqual(succeeded, true)
        XCTAssertTrue(issues.isEmpty)
    }

    func testXcodebuildLinkerError() {
        let output = """
        ld: symbol(s) not found for architecture arm64
        clang: error: linker command failed with exit code 1 (use -v to see invocation)
        ** BUILD FAILED **
        """

        let (issues, _, succeeded) = XcodebuildParser.parse(output)
        XCTAssertEqual(succeeded, false)
        let linkerIssues = issues.filter { $0.severity == .error }
        XCTAssertTrue(linkerIssues.count >= 2)
    }

    func testXcodebuildTestFailure() {
        let output = """
        Test Suite 'CommandCenterTests' started at 2024-01-15 10:30:00.000.
        Test Case '-[CommandCenterTests.BuildTests testFoo]' started.
        /Users/tj/Project/Tests/BuildTests.swift:42: error: -[CommandCenterTests.BuildTests testFoo] : XCTAssertEqual failed: ("a") is not equal to ("b")
        Test Case '-[CommandCenterTests.BuildTests testFoo]' failed (0.002 seconds).
        ** TEST FAILED **
        """

        let (issues, failures, succeeded) = XcodebuildParser.parse(output)
        XCTAssertEqual(succeeded, false)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].suite, "CommandCenterTests.BuildTests")
        XCTAssertEqual(failures[0].testCase, "testFoo")
        XCTAssertTrue(failures[0].message.contains("XCTAssertEqual failed"))

        XCTAssertEqual(issues.filter { $0.testName != nil }.count, 1)
    }

    // MARK: - Build Report Builder

    func testBuildReportFromSwiftBuildFailure() {
        let output = """
        Building for debugging...
        /Users/tj/Project/Sources/Foo.swift:42:13: error: value of type 'String' has no member 'count2'
        /Users/tj/Project/Sources/Bar.swift:10:5: error: missing return in global function expected to return 'Int'
        /Users/tj/Project/Sources/Bar.swift:15:1: warning: result of call to 'print' is unused
        Build complete! (failed)
        """

        let report = BuildReportBuilder.build(command: "swift build", output: output, exitStatus: 1)
        XCTAssertNotNil(report)
        XCTAssertFalse(report!.succeeded)
        XCTAssertEqual(report!.errorCount, 2)
        XCTAssertEqual(report!.warningCount, 1)
        XCTAssertEqual(report!.errorFiles.count, 2)
        XCTAssertTrue(report!.failedTests.isEmpty)
    }

    func testBuildReportFromSwiftTestFailure() {
        let output = """
        Building for testing...
        Build complete! (1.23s)
        Test Suite 'All tests' started.
        /Users/tj/Project/Tests/FooTests.swift:10: error: -[FooTests testA] : XCTAssertTrue failed
        Test Case '-[FooTests testA]' failed (0.001 seconds).
        Executed 10 tests, with 1 failure (0 unexpected) in 0.500 (0.501) seconds
        """

        let report = BuildReportBuilder.build(command: "swift test", output: output, exitStatus: 1)
        XCTAssertNotNil(report)
        XCTAssertFalse(report!.succeeded)
        XCTAssertEqual(report!.failedTests.count, 1)
        XCTAssertEqual(report!.failedTests[0].testCase, "testA")
    }

    func testBuildReportReturnsNilForNonBuildCommand() {
        let report = BuildReportBuilder.build(command: "ls -la", output: "total 42", exitStatus: 0)
        XCTAssertNil(report)
    }

    // MARK: - Report Formatting

    func testFormatBuildFailedWithErrors() {
        let report = BuildReport(
            succeeded: false,
            issues: [
                BuildIssue(id: "1", source: .swiftBuild, severity: .error, file: "Sources/Foo.swift", line: 42, message: "type error", rawLine: ""),
                BuildIssue(id: "2", source: .swiftBuild, severity: .error, file: "Sources/Bar.swift", line: 10, message: "missing return", rawLine: ""),
            ],
            failedTests: [],
            rawTail: ""
        )

        let formatted = BuildReportFormatter.format(report, command: "swift build")
        XCTAssertTrue(formatted.contains("Build failed"))
        XCTAssertTrue(formatted.contains("2 errors"))
        XCTAssertTrue(formatted.contains("2 files"))
        XCTAssertTrue(formatted.contains("Sources/Foo.swift:42"))
        XCTAssertTrue(formatted.contains("Sources/Bar.swift:10"))
    }

    func testFormatTestFailures() {
        let report = BuildReport(
            succeeded: false,
            issues: [
                BuildIssue(id: "1", source: .swiftTest, severity: .error, file: "Tests/FooTests.swift", line: 10, message: "FooTests.testA(): XCTAssertTrue failed", testName: "FooTests.testA", rawLine: ""),
            ],
            failedTests: [
                TestFailure(suite: "FooTests", testCase: "testA", message: "XCTAssertTrue failed", file: "Tests/FooTests.swift", line: 10, rawLine: "...")
            ],
            rawTail: ""
        )

        let formatted = BuildReportFormatter.format(report, command: "swift test")
        XCTAssertTrue(formatted.contains("1 test failed"))
        XCTAssertTrue(formatted.contains("FooTests.testA()"))
        XCTAssertTrue(formatted.contains("Tests/FooTests.swift:10"))
    }

    func testFormatCleanBuild() {
        let report = BuildReport(
            succeeded: true,
            issues: [],
            failedTests: [],
            rawTail: ""
        )

        let formatted = BuildReportFormatter.format(report, command: "swift build")
        XCTAssertEqual(formatted, "Build succeeded.")
    }

    func testFormatWarningsOnly() {
        let report = BuildReport(
            succeeded: true,
            issues: [
                BuildIssue(id: "1", source: .swiftBuild, severity: .warning, file: "Foo.swift", line: 5, message: "unused var", rawLine: ""),
            ],
            failedTests: [],
            rawTail: ""
        )

        let formatted = BuildReportFormatter.format(report, command: "swift build")
        XCTAssertTrue(formatted.contains("Build succeeded"))
        XCTAssertTrue(formatted.contains("1 warning"))
    }

    // MARK: - Path Shortening

    func testPathShorteningInIssues() {
        let output = """
        /Users/tj/Desktop/Studio.92/Sources/AgentCouncil/Foo.swift:10:5: error: some error
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertEqual(issues.count, 1)
        // Should be shortened to Sources/... not full absolute path
        XCTAssertTrue(issues[0].file?.hasPrefix("Sources/") ?? false)
    }

    func testPathShorteningForCommandCenter() {
        let output = """
        /Users/tj/Desktop/Studio.92/CommandCenter/PipelineRunner.swift:842:30: error: actor-isolated
        """

        let issues = SwiftBuildParser.parse(output)
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].file?.hasPrefix("CommandCenter/") ?? false)
    }

    // MARK: - Full Tool Result Integration

    func testFormattedToolResultStructured() {
        let output = """
        Building for debugging...
        /Users/tj/Project/Sources/Foo.swift:42:13: error: cannot convert value
        Build complete! (failed)
        """

        let report = BuildReportBuilder.build(command: "swift build", output: output, exitStatus: 1)!
        let result = BuildReportFormatter.formattedToolResult(
            command: "swift build",
            report: report,
            rawOutput: output,
            exitStatus: 1,
            didTimeout: false
        )

        XCTAssertTrue(result.contains("Command: swift build"))
        XCTAssertTrue(result.contains("Exit status: 1"))
        XCTAssertTrue(result.contains("Build failed"))
        XCTAssertTrue(result.contains("1 error"))
        XCTAssertTrue(result.contains("cannot convert value"))
        XCTAssertTrue(result.contains("Raw output"))
    }
}
