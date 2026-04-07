import Foundation

public struct ExactSearchRequest: Sendable, Equatable {
    public let query: String
    public let isRegexp: Bool
    public let caseSensitive: Bool
    public let targets: [URL]
    public let maxResults: Int
    public let contextLines: Int

    public init(
        query: String,
        isRegexp: Bool = false,
        caseSensitive: Bool = false,
        targets: [URL] = [],
        maxResults: Int = 50,
        contextLines: Int = 1
    ) {
        self.query = query
        self.isRegexp = isRegexp
        self.caseSensitive = caseSensitive
        self.targets = targets
        self.maxResults = maxResults
        self.contextLines = contextLines
    }
}

public struct ExactSearchMatch: Sendable, Codable, Equatable {
    public let path: String
    public let line: Int
    public let column: Int
    public let lineText: String
    public let before: [String]
    public let after: [String]

    enum CodingKeys: String, CodingKey {
        case path, line, column, before, after
        case lineText = "line_text"
    }
}

public struct ExactSearchResult: Sendable, Codable, Equatable {
    public let query: String
    public let isRegexp: Bool
    public let caseSensitive: Bool
    public let queryTimeMs: Int
    public let totalMatches: Int
    public let returnedMatches: Int
    public let truncated: Bool
    public let matches: [ExactSearchMatch]

    public init(
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool,
        queryTimeMs: Int,
        totalMatches: Int,
        returnedMatches: Int,
        truncated: Bool,
        matches: [ExactSearchMatch]
    ) {
        self.query = query
        self.isRegexp = isRegexp
        self.caseSensitive = caseSensitive
        self.queryTimeMs = queryTimeMs
        self.totalMatches = totalMatches
        self.returnedMatches = returnedMatches
        self.truncated = truncated
        self.matches = matches
    }

    public var fileCount: Int {
        Set(matches.map(\.path)).count
    }

    public func prettyPrintedJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"query\":\"\(escapedQuery)\"}"
        }
        return text
    }

    enum CodingKeys: String, CodingKey {
        case query, truncated, matches
        case isRegexp = "is_regexp"
        case caseSensitive = "case_sensitive"
        case queryTimeMs = "query_time_ms"
        case totalMatches = "total_matches"
        case returnedMatches = "returned_matches"
    }
}

public enum ExactSearchEngineError: LocalizedError, Sendable {
    case emptyQuery
    case commandFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Search query cannot be empty."
        case .commandFailed(let message):
            return message
        }
    }
}

public enum ExactSearchEngine {

    public static func search(
        request: ExactSearchRequest,
        projectRoot: URL
    ) async throws -> ExactSearchResult {
        try await Task.detached(priority: .userInitiated) {
            try searchSynchronously(request: request, projectRoot: projectRoot.standardizedFileURL)
        }.value
    }

    private static func searchSynchronously(
        request: ExactSearchRequest,
        projectRoot: URL
    ) throws -> ExactSearchResult {
        let startedAt = Date()
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ExactSearchEngineError.emptyQuery }

        let maxResults = min(max(request.maxResults, 1), 500)
        let contextLines = min(max(request.contextLines, 0), 5)
        let targets = resolvedTargets(from: request.targets, projectRoot: projectRoot)

        let rgOutcome = try run(command: ripgrepArguments(
            query: query,
            isRegexp: request.isRegexp,
            caseSensitive: request.caseSensitive,
            targets: targets
        ), currentDirectory: projectRoot)

        let parsedMatches: [ParsedMatch]
        switch rgOutcome.exitCode {
        case 0, 1:
            parsedMatches = parseRipgrepMatches(rgOutcome.stdout, projectRoot: projectRoot)
        case 127:
            let grepOutcome = try run(command: grepArguments(
                query: query,
                isRegexp: request.isRegexp,
                caseSensitive: request.caseSensitive,
                targets: targets
            ), currentDirectory: projectRoot)
            guard grepOutcome.exitCode == 0 || grepOutcome.exitCode == 1 else {
                let message = grepOutcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ExactSearchEngineError.commandFailed(message: message.isEmpty ? "grep_search failed." : message)
            }
            parsedMatches = parseGrepMatches(
                grepOutcome.stdout,
                query: query,
                isRegexp: request.isRegexp,
                caseSensitive: request.caseSensitive,
                projectRoot: projectRoot
            )
        default:
            let message = rgOutcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExactSearchEngineError.commandFailed(message: message.isEmpty ? "grep_search failed." : message)
        }

        let orderedMatches = parsedMatches.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.column < $1.column
        }

        let totalMatches = orderedMatches.count
        let truncated = totalMatches > maxResults
        let limitedMatches = Array(orderedMatches.prefix(maxResults))
        let contextualized = attachContext(to: limitedMatches, contextLines: contextLines, projectRoot: projectRoot)
        let queryTimeMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000.0))

        return ExactSearchResult(
            query: query,
            isRegexp: request.isRegexp,
            caseSensitive: request.caseSensitive,
            queryTimeMs: queryTimeMs,
            totalMatches: totalMatches,
            returnedMatches: contextualized.count,
            truncated: truncated,
            matches: contextualized
        )
    }

    private static func ripgrepArguments(
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool,
        targets: [String]
    ) -> [String] {
        var args = [
            "rg",
            "--json",
            "--line-number",
            "--column",
            "--no-heading",
            "--color",
            "never",
            "--no-messages"
        ]
        if !isRegexp {
            args.append("--fixed-strings")
        }
        if !caseSensitive {
            args.append("--ignore-case")
        }
        args.append(query)
        args.append(contentsOf: targets)
        return args
    }

    private static func grepArguments(
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool,
        targets: [String]
    ) -> [String] {
        var args = ["grep", "-R", "-H", "-n", "-I"]
        args.append(isRegexp ? "-E" : "-F")
        if !caseSensitive {
            args.append("-i")
        }
        args.append(query)
        args.append(contentsOf: targets)
        return args
    }

    private static func resolvedTargets(from urls: [URL], projectRoot: URL) -> [String] {
        guard !urls.isEmpty else { return ["."] }

        let normalizedRoot = projectRoot.standardizedFileURL.path
        let resolved = urls.compactMap { url -> String? in
            let candidate = url.standardizedFileURL.path
            if candidate == normalizedRoot {
                return "."
            }
            guard candidate.hasPrefix(normalizedRoot + "/") else { return nil }
            return String(candidate.dropFirst(normalizedRoot.count + 1))
        }

        return resolved.isEmpty ? ["."] : resolved
    }

    private static func parseRipgrepMatches(_ output: String, projectRoot: URL) -> [ParsedMatch] {
        var matches: [ParsedMatch] = []
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(RipgrepEvent.self, from: data),
                  event.type == "match",
                  let payload = event.data,
                  let rawPath = payload.path?.text,
                  let lineText = payload.lines?.text,
                  let lineNumber = payload.lineNumber else {
                continue
            }

            let path = normalizedResultPath(rawPath, projectRoot: projectRoot)
            let renderedLine = trimmedLineText(lineText)
            let columns = payload.submatches?.map { max(1, $0.start + 1) } ?? [1]
            matches.append(contentsOf: columns.map {
                ParsedMatch(
                    path: path,
                    line: lineNumber,
                    column: $0,
                    lineText: renderedLine
                )
            })
        }
        return matches
    }

    private static func parseGrepMatches(
        _ output: String,
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool,
        projectRoot: URL
    ) -> [ParsedMatch] {
        let expression = compiledExpression(query: query, isRegexp: isRegexp, caseSensitive: caseSensitive)

        let linePattern = #"^(.+?):(\d+):(.*)$"#
        guard let lineRegex = try? NSRegularExpression(pattern: linePattern) else { return [] }

        var matches: [ParsedMatch] = []
        for line in output.split(separator: "\n") {
            let lineString = String(line)
            guard let match = lineRegex.firstMatch(in: lineString, range: NSRange(location: 0, length: lineString.utf16.count)),
                  let pathRange = Range(match.range(at: 1), in: lineString),
                  let lineRange = Range(match.range(at: 2), in: lineString),
                  let textRange = Range(match.range(at: 3), in: lineString),
                  let lineNumber = Int(lineString[lineRange]) else {
                continue
            }

            let rawPath = String(lineString[pathRange])
            let lineText = String(lineString[textRange])
            let path = normalizedResultPath(rawPath, projectRoot: projectRoot)
            let columns = matchColumns(
                in: lineText,
                query: query,
                isRegexp: isRegexp,
                caseSensitive: caseSensitive,
                expression: expression
            )
            matches.append(contentsOf: columns.map {
                ParsedMatch(
                    path: path,
                    line: lineNumber,
                    column: $0,
                    lineText: lineText
                )
            })
        }

        return matches
    }

    private static func attachContext(
        to matches: [ParsedMatch],
        contextLines: Int,
        projectRoot: URL
    ) -> [ExactSearchMatch] {
        guard contextLines > 0 else {
            return matches.map {
                ExactSearchMatch(
                    path: $0.path,
                    line: $0.line,
                    column: $0.column,
                    lineText: $0.lineText,
                    before: [],
                    after: []
                )
            }
        }

        let grouped = Dictionary(grouping: matches, by: \.path)
        var contextByPath: [String: [String]] = [:]

        for path in grouped.keys {
            let fileURL: URL
            if path.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: path)
            } else {
                fileURL = projectRoot.appendingPathComponent(path)
            }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            contextByPath[path] = content.components(separatedBy: .newlines)
        }

        return matches.map { match in
            let lines = contextByPath[match.path] ?? []
            let lineIndex = max(0, match.line - 1)
            let beforeStart = max(0, lineIndex - contextLines)
            let before = Array(lines[beforeStart..<min(lineIndex, lines.count)])
            let afterStart = min(lineIndex + 1, lines.count)
            let afterEnd = min(afterStart + contextLines, lines.count)
            let after = afterStart < afterEnd ? Array(lines[afterStart..<afterEnd]) : []
            return ExactSearchMatch(
                path: match.path,
                line: match.line,
                column: match.column,
                lineText: match.lineText,
                before: before,
                after: after
            )
        }
    }

    private static func normalizedResultPath(_ rawPath: String, projectRoot: URL) -> String {
        let trimmed = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        let root = projectRoot.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: trimmed, relativeTo: rawPath.hasPrefix("/") ? nil : projectRoot)
            .standardizedFileURL.path

        if standardized == root {
            return "."
        }
        if standardized.hasPrefix(root + "/") {
            return String(standardized.dropFirst(root.count + 1))
        }
        return trimmed
    }

    private static func compiledExpression(
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool
    ) -> NSRegularExpression? {
        guard isRegexp else { return nil }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: query, options: options)
    }

    private static func matchColumns(
        in lineText: String,
        query: String,
        isRegexp: Bool,
        caseSensitive: Bool,
        expression: NSRegularExpression?
    ) -> [Int] {
        if isRegexp, let expression {
            let nsRange = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
            let matches = expression.matches(in: lineText, range: nsRange)
            return matches.compactMap { match in
                guard let range = Range(match.range, in: lineText) else { return nil }
                return lineText.distance(from: lineText.startIndex, to: range.lowerBound) + 1
            }
        }

        let source = caseSensitive ? lineText : lineText.lowercased()
        let needle = caseSensitive ? query : query.lowercased()
        guard !needle.isEmpty else { return [] }

        var columns: [Int] = []
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(of: needle, range: searchStart..<source.endIndex) {
            columns.append(source.distance(from: source.startIndex, to: range.lowerBound) + 1)
            searchStart = range.upperBound
        }
        return columns
    }

    private static func trimmedLineText(_ text: String) -> String {
        text.trimmingCharacters(in: .newlines)
    }

    private static func run(command: [String], currentDirectory: URL) throws -> CommandOutcome {
        precondition(!command.isEmpty)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return CommandOutcome(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private struct ParsedMatch {
    let path: String
    let line: Int
    let column: Int
    let lineText: String
}

private struct CommandOutcome {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct RipgrepEvent: Decodable {
    let type: String
    let data: RipgrepEventData?
}

private struct RipgrepEventData: Decodable {
    let path: RipgrepText?
    let lines: RipgrepText?
    let lineNumber: Int?
    let submatches: [RipgrepSubmatch]?

    enum CodingKeys: String, CodingKey {
        case path, lines, submatches
        case lineNumber = "line_number"
    }
}

private struct RipgrepText: Decodable {
    let text: String
}

private struct RipgrepSubmatch: Decodable {
    let start: Int
    let end: Int
}