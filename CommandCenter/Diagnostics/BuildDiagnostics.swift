// BuildDiagnostics.swift
// Studio.92 — Command Center
// Structured extraction of build/test failures from raw tool output.
// Replaces raw log dumps with normalized BuildIssue / BuildReport models.

import Foundation

// MARK: - Models

struct BuildIssue: Identifiable, Codable, Hashable, Sendable {
    enum Severity: String, Codable, Sendable { case error, warning, note }
    enum Source: String, Codable, Sendable { case xcodebuild, swiftBuild, swiftTest, xctest }

    var id: String
    var source: Source
    var severity: Severity
    var file: String?
    var line: Int?
    var column: Int?
    var message: String
    var target: String?
    var testName: String?
    var rawLine: String
}

struct TestFailure: Codable, Hashable, Sendable {
    var suite: String
    var testCase: String
    var message: String
    var file: String?
    var line: Int?
    var rawLine: String
}

struct BuildReport: Codable, Equatable, Sendable {
    var succeeded: Bool
    var issues: [BuildIssue]
    var failedTests: [TestFailure]
    var rawTail: String

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var errorFiles: Set<String> { Set(issues.filter { $0.severity == .error }.compactMap(\.file)) }
}

// MARK: - Command Detection

enum BuildCommandKind: Sendable {
    case swiftBuild
    case swiftTest
    case xcodebuild

    init?(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Match common patterns: "swift build ...", "swift test ...", "xcodebuild ..."
        // Also handle prefixed forms like "cd foo && swift build"
        let tokens = trimmed.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Find the effective command after any chained operators
        let segments = trimmed.components(separatedBy: "&&")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let last = segments.last ?? trimmed

        if last.hasPrefix("swift test") || last.hasPrefix("swift package test") {
            self = .swiftTest
        } else if last.hasPrefix("swift build") || last.hasPrefix("swift package build") {
            self = .swiftBuild
        } else if last.hasPrefix("xcodebuild") {
            self = .xcodebuild
        } else if tokens.contains("swift") && tokens.contains("test") {
            self = .swiftTest
        } else if tokens.contains("swift") && tokens.contains("build") {
            self = .swiftBuild
        } else if tokens.contains("xcodebuild") {
            self = .xcodebuild
        } else {
            return nil
        }
    }
}

// MARK: - Parsers

enum SwiftBuildParser {

    // Pattern: /path/to/File.swift:42:13: error: some message
    // Also matches warning and note
    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#,
        options: []
    )

    // Pattern: error: some message (no file location)
    private static let bareErrorPattern = try! NSRegularExpression(
        pattern: #"^(error|warning|note):\s*(.+)$"#,
        options: []
    )

    // Linker error: ld: symbol(s) not found / clang: error: linker command failed
    private static let linkerPattern = try! NSRegularExpression(
        pattern: #"^(ld|clang):\s*(error:\s*)?(.+)$"#,
        options: []
    )

    static func parse(_ output: String) -> [BuildIssue] {
        var issues: [BuildIssue] = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            if let match = diagnosticPattern.firstMatch(in: trimmed, range: range) {
                let file = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let lineNum = Int(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let col = Int(trimmed[Range(match.range(at: 3), in: trimmed)!])
                let sevStr = String(trimmed[Range(match.range(at: 4), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                let severity: BuildIssue.Severity
                switch sevStr {
                case "error": severity = .error
                case "warning": severity = .warning
                default: severity = .note
                }

                issues.append(BuildIssue(
                    id: "swiftbuild-\(index)",
                    source: .swiftBuild,
                    severity: severity,
                    file: shortenPath(file),
                    line: lineNum,
                    column: col,
                    message: message,
                    rawLine: trimmed
                ))
                continue
            }

            if let match = bareErrorPattern.firstMatch(in: trimmed, range: range) {
                let sevStr = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 2), in: trimmed)!])

                let severity: BuildIssue.Severity
                switch sevStr {
                case "error": severity = .error
                case "warning": severity = .warning
                default: severity = .note
                }

                issues.append(BuildIssue(
                    id: "swiftbuild-bare-\(index)",
                    source: .swiftBuild,
                    severity: severity,
                    message: message,
                    rawLine: trimmed
                ))
                continue
            }

            if let match = linkerPattern.firstMatch(in: trimmed, range: range) {
                let tool = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 3), in: trimmed)!])

                issues.append(BuildIssue(
                    id: "swiftbuild-linker-\(index)",
                    source: .swiftBuild,
                    severity: .error,
                    message: "\(tool): \(message)",
                    rawLine: trimmed
                ))
            }
        }

        return issues
    }
}

enum SwiftTestParser {

    // Test failure: /path/File.swift:42: error: -[Module.Suite testCase] : XCTAssertEqual failed...
    private static let xcTestFailurePattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):\s*error:\s*-\[(\S+)\s+(\S+)\]\s*:\s*(.+)$"#,
        options: []
    )

    // Swift Testing failure: Test "name" recorded an issue at File.swift:42:13: message
    private static let swiftTestingFailurePattern = try! NSRegularExpression(
        pattern: #"^.*Test\s+"([^"]+)"\s+recorded an issue.*?(?:at\s+(.+?):(\d+)(?::(\d+))?)?\s*:\s*(.+)$"#,
        options: []
    )

    // Compile error during test build (same as swift build)
    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#,
        options: []
    )

    // Test suite summary: "Executed N tests, with M failures (K unexpected)"
    private static let summaryPattern = try! NSRegularExpression(
        pattern: #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failure"#,
        options: []
    )

    // Test crash: "Test Case '-[Suite test]' crashed"
    private static let crashPattern = try! NSRegularExpression(
        pattern: #"Test Case\s+'.*?-\[(\S+)\s+(\S+)\]'\s+(?:crashed|passed|failed)\s*\((\d+\.\d+)\s*seconds\)"#,
        options: []
    )

    // Failed test case line: "Test Case '-[Suite test]' failed (0.001 seconds)."
    private static let failedCasePattern = try! NSRegularExpression(
        pattern: #"Test Case\s+'-\[(\S+)\s+(\S+)\]'\s+failed"#,
        options: []
    )

    static func parse(_ output: String) -> (issues: [BuildIssue], failures: [TestFailure]) {
        var issues: [BuildIssue] = []
        var failures: [TestFailure] = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // XCTest assertion failure
            if let match = xcTestFailurePattern.firstMatch(in: trimmed, range: range) {
                let file = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let lineNum = Int(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let suite = String(trimmed[Range(match.range(at: 3), in: trimmed)!])
                let testCase = String(trimmed[Range(match.range(at: 4), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                failures.append(TestFailure(
                    suite: suite,
                    testCase: testCase,
                    message: message,
                    file: shortenPath(file),
                    line: lineNum,
                    rawLine: trimmed
                ))

                issues.append(BuildIssue(
                    id: "swifttest-\(index)",
                    source: .swiftTest,
                    severity: .error,
                    file: shortenPath(file),
                    line: lineNum,
                    message: "\(suite).\(testCase)(): \(message)",
                    testName: "\(suite).\(testCase)",
                    rawLine: trimmed
                ))
                continue
            }

            // Swift Testing failure
            if let match = swiftTestingFailurePattern.firstMatch(in: trimmed, range: range) {
                let testName = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let file = match.range(at: 2).location != NSNotFound
                    ? String(trimmed[Range(match.range(at: 2), in: trimmed)!]) : nil
                let lineNum = match.range(at: 3).location != NSNotFound
                    ? Int(trimmed[Range(match.range(at: 3), in: trimmed)!]) : nil
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                failures.append(TestFailure(
                    suite: "",
                    testCase: testName,
                    message: message,
                    file: file.map(shortenPath),
                    line: lineNum,
                    rawLine: trimmed
                ))

                issues.append(BuildIssue(
                    id: "swifttesting-\(index)",
                    source: .swiftTest,
                    severity: .error,
                    file: file.map(shortenPath),
                    line: lineNum,
                    message: "\(testName): \(message)",
                    testName: testName,
                    rawLine: trimmed
                ))
                continue
            }

            // Compile error during test build
            if let match = diagnosticPattern.firstMatch(in: trimmed, range: range) {
                let file = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let lineNum = Int(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let col = Int(trimmed[Range(match.range(at: 3), in: trimmed)!])
                let sevStr = String(trimmed[Range(match.range(at: 4), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                let severity: BuildIssue.Severity
                switch sevStr {
                case "error": severity = .error
                case "warning": severity = .warning
                default: severity = .note
                }

                issues.append(BuildIssue(
                    id: "swifttest-compile-\(index)",
                    source: .swiftTest,
                    severity: severity,
                    file: shortenPath(file),
                    line: lineNum,
                    column: col,
                    message: message,
                    rawLine: trimmed
                ))
                continue
            }
        }

        return (issues, failures)
    }
}

enum XcodebuildParser {

    // Xcode diagnostic: /path/File.swift:42:13: error: some message
    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+):\s*(error|warning|note):\s*(.+)$"#,
        options: []
    )

    // Xcode error summary line: "❌  error: some message"
    // or "error: Build input file cannot be found: ..."
    private static let errorSummaryPattern = try! NSRegularExpression(
        pattern: #"^(?:❌\s+)?error:\s*(.+)$"#,
        options: []
    )

    // Linker errors
    private static let linkerPattern = try! NSRegularExpression(
        pattern: #"^(ld|clang):\s*(error:\s*)?(.+)$"#,
        options: []
    )

    // Target context: "CompileSwift normal x86_64 /path/File.swift (in target 'Foo' ...)"
    private static let targetContextPattern = try! NSRegularExpression(
        pattern: #"\(in target '([^']+)'"#,
        options: []
    )

    // BUILD SUCCEEDED / BUILD FAILED
    private static let resultPattern = try! NSRegularExpression(
        pattern: #"\*\*\s*(BUILD|TEST)\s+(SUCCEEDED|FAILED)\s*\*\*"#,
        options: []
    )

    // Xcode test failure: file:line: error: -[Suite test] : message
    private static let testFailurePattern = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):\s*error:\s*-\[(\S+)\s+(\S+)\]\s*:\s*(.+)$"#,
        options: []
    )

    static func parse(_ output: String) -> (issues: [BuildIssue], failures: [TestFailure], succeeded: Bool?) {
        var issues: [BuildIssue] = []
        var failures: [TestFailure] = []
        var succeeded: Bool? = nil
        var currentTarget: String? = nil
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Track current target from compile commands
            if let match = targetContextPattern.firstMatch(in: trimmed, range: range) {
                currentTarget = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
            }

            // Build result
            if let match = resultPattern.firstMatch(in: trimmed, range: range) {
                let result = String(trimmed[Range(match.range(at: 2), in: trimmed)!])
                succeeded = (result == "SUCCEEDED")
            }

            // Test failure (same as XCTest format)
            if let match = testFailurePattern.firstMatch(in: trimmed, range: range) {
                let file = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let lineNum = Int(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let suite = String(trimmed[Range(match.range(at: 3), in: trimmed)!])
                let testCase = String(trimmed[Range(match.range(at: 4), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                failures.append(TestFailure(
                    suite: suite,
                    testCase: testCase,
                    message: message,
                    file: shortenPath(file),
                    line: lineNum,
                    rawLine: trimmed
                ))

                issues.append(BuildIssue(
                    id: "xcodebuild-test-\(index)",
                    source: .xcodebuild,
                    severity: .error,
                    file: shortenPath(file),
                    line: lineNum,
                    message: "\(suite).\(testCase)(): \(message)",
                    target: currentTarget,
                    testName: "\(suite).\(testCase)",
                    rawLine: trimmed
                ))
                continue
            }

            // File-located diagnostic
            if let match = diagnosticPattern.firstMatch(in: trimmed, range: range) {
                let file = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let lineNum = Int(trimmed[Range(match.range(at: 2), in: trimmed)!])
                let col = Int(trimmed[Range(match.range(at: 3), in: trimmed)!])
                let sevStr = String(trimmed[Range(match.range(at: 4), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 5), in: trimmed)!])

                let severity: BuildIssue.Severity
                switch sevStr {
                case "error": severity = .error
                case "warning": severity = .warning
                default: severity = .note
                }

                issues.append(BuildIssue(
                    id: "xcodebuild-\(index)",
                    source: .xcodebuild,
                    severity: severity,
                    file: shortenPath(file),
                    line: lineNum,
                    column: col,
                    message: message,
                    target: currentTarget,
                    rawLine: trimmed
                ))
                continue
            }

            // Bare error summary
            if let match = errorSummaryPattern.firstMatch(in: trimmed, range: range) {
                let message = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                // Skip duplicates of file-located diagnostics
                if !issues.contains(where: { $0.message == message }) {
                    issues.append(BuildIssue(
                        id: "xcodebuild-summary-\(index)",
                        source: .xcodebuild,
                        severity: .error,
                        message: message,
                        target: currentTarget,
                        rawLine: trimmed
                    ))
                }
                continue
            }

            // Linker error
            if let match = linkerPattern.firstMatch(in: trimmed, range: range) {
                let tool = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                let message = String(trimmed[Range(match.range(at: 3), in: trimmed)!])

                issues.append(BuildIssue(
                    id: "xcodebuild-linker-\(index)",
                    source: .xcodebuild,
                    severity: .error,
                    message: "\(tool): \(message)",
                    target: currentTarget,
                    rawLine: trimmed
                ))
            }
        }

        return (issues, failures, succeeded)
    }
}

// MARK: - Report Builder

enum BuildReportBuilder {

    static func build(command: String, output: String, exitStatus: Int) -> BuildReport? {
        guard let kind = BuildCommandKind(command: command) else { return nil }

        let rawTail = String(output.suffix(2000))

        switch kind {
        case .swiftBuild:
            let issues = SwiftBuildParser.parse(output)
            return BuildReport(
                succeeded: exitStatus == 0,
                issues: issues,
                failedTests: [],
                rawTail: rawTail
            )

        case .swiftTest:
            let (issues, failures) = SwiftTestParser.parse(output)
            return BuildReport(
                succeeded: exitStatus == 0 && failures.isEmpty,
                issues: issues,
                failedTests: failures,
                rawTail: rawTail
            )

        case .xcodebuild:
            let (issues, failures, buildSucceeded) = XcodebuildParser.parse(output)
            return BuildReport(
                succeeded: buildSucceeded ?? (exitStatus == 0),
                issues: issues,
                failedTests: failures,
                rawTail: rawTail
            )
        }
    }
}

// MARK: - Report Formatting

enum BuildReportFormatter {

    static func format(_ report: BuildReport, command: String) -> String {
        var sections: [String] = []

        // Status line
        let status = report.succeeded ? "Build succeeded" : "Build failed"
        if report.errorCount > 0 || !report.failedTests.isEmpty {
            var parts = [status]
            if report.errorCount > 0 {
                let fileCount = report.errorFiles.count
                parts.append("with \(report.errorCount) error\(report.errorCount == 1 ? "" : "s") in \(fileCount) file\(fileCount == 1 ? "" : "s")")
            }
            if !report.failedTests.isEmpty {
                parts.append("\(report.failedTests.count) test\(report.failedTests.count == 1 ? "" : "s") failed")
            }
            sections.append(parts.joined(separator: ", ") + ".")
        } else if report.warningCount > 0 {
            sections.append("\(status) with \(report.warningCount) warning\(report.warningCount == 1 ? "" : "s").")
        } else {
            sections.append("\(status).")
        }

        // Errors
        let errors = report.issues.filter { $0.severity == .error && $0.testName == nil }
        if !errors.isEmpty {
            var block = "Errors:"
            for issue in errors {
                if let file = issue.file, let line = issue.line {
                    block += "\n  \(file):\(line): \(issue.message)"
                } else {
                    block += "\n  \(issue.message)"
                }
            }
            sections.append(block)
        }

        // Test failures
        if !report.failedTests.isEmpty {
            var block = "Test failures:"
            for failure in report.failedTests {
                let location: String
                if let file = failure.file, let line = failure.line {
                    location = " at \(file):\(line)"
                } else {
                    location = ""
                }
                let suiteDot = failure.suite.isEmpty ? "" : "\(failure.suite)."
                block += "\n  \(suiteDot)\(failure.testCase)()\(location): \(failure.message)"
            }
            sections.append(block)
        }

        // Warnings (compact)
        let warnings = report.issues.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            var block = "Warnings:"
            for warning in warnings.prefix(10) {
                if let file = warning.file, let line = warning.line {
                    block += "\n  \(file):\(line): \(warning.message)"
                } else {
                    block += "\n  \(warning.message)"
                }
            }
            if warnings.count > 10 {
                block += "\n  ... and \(warnings.count - 10) more"
            }
            sections.append(block)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Produces a structured + raw tool result for the model.
    /// Structured summary first, then raw tail for fallback context.
    static func formattedToolResult(
        command: String,
        report: BuildReport,
        rawOutput: String,
        exitStatus: Int,
        didTimeout: Bool
    ) -> String {
        var parts: [String] = []

        parts.append("Command: \(command)")
        parts.append("Exit status: \(exitStatus)")
        if didTimeout {
            parts.append("Timed out: true")
        }

        // Structured summary
        let summary = format(report, command: command)
        parts.append(summary)

        // Raw tail for context the model might need
        let tail = report.rawTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append("Raw output (last 2000 chars):\n\(tail)")
        }

        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Helpers

private func shortenPath(_ path: String) -> String {
    // Strip common prefixes to make paths readable
    let components = path.components(separatedBy: "/")
    // Find the last meaningful directory (Sources/, Tests/, CommandCenter/)
    if let idx = components.lastIndex(where: { $0 == "Sources" || $0 == "Tests" || $0 == "CommandCenter" }) {
        return components[idx...].joined(separator: "/")
    }
    // If path has more than 3 components, show last 3
    if components.count > 3 {
        return components.suffix(3).joined(separator: "/")
    }
    return path
}
