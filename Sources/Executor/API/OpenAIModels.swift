// OpenAIModels.swift
// Studio.92 — Executor
// Codable types for OpenAI Chat Completions API.

import Foundation

// MARK: - Model

public enum OpenAIModel: String, Sendable {
    case gpt45 = "gpt-4.5-preview"
}

// MARK: - Request

public struct OpenAIRequest: Encodable, Sendable {
    public let model: String
    public let messages: [OpenAIMessage]
    public let max_tokens: Int
    public let temperature: Double
    public let response_format: ResponseFormat

    public init(
        model:          String = OpenAIModel.gpt45.rawValue,
        messages:        [OpenAIMessage],
        maxTokens:       Int    = 4096,
        temperature:     Double = 0.1,
        responseFormat:  ResponseFormat = .json
    ) {
        self.model           = model
        self.messages        = messages
        self.max_tokens      = maxTokens
        self.temperature     = temperature
        self.response_format = responseFormat
    }
}

public struct ResponseFormat: Encodable, Sendable {
    public let type: String

    public static let json = ResponseFormat(type: "json_object")
    public static let text = ResponseFormat(type: "text")
}

// MARK: - Message

public enum OpenAIRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

public struct OpenAIMessage: Codable, Sendable {
    public let role: OpenAIRole
    public let content: String

    public init(role: OpenAIRole, content: String) {
        self.role    = role
        self.content = content
    }

    public static func system(_ text: String) -> OpenAIMessage {
        OpenAIMessage(role: .system, content: text)
    }

    public static func user(_ text: String) -> OpenAIMessage {
        OpenAIMessage(role: .user, content: text)
    }

    public static func assistant(_ text: String) -> OpenAIMessage {
        OpenAIMessage(role: .assistant, content: text)
    }
}

// MARK: - Response

public struct OpenAIResponse: Decodable, Sendable {
    public let id: String
    public let choices: [OpenAIChoice]
    public let model: String
    public let usage: OpenAIUsage

    public var text: String {
        choices.first?.message.content ?? ""
    }
}

public struct OpenAIChoice: Decodable, Sendable {
    public let index: Int
    public let message: OpenAIChoiceMessage
    public let finish_reason: String?
}

public struct OpenAIChoiceMessage: Decodable, Sendable {
    public let role: String
    public let content: String
}

public struct OpenAIUsage: Decodable, Sendable {
    public let prompt_tokens: Int
    public let completion_tokens: Int
    public let total_tokens: Int
}

// MARK: - Errors

public enum ExecutorError: Error, CustomStringConvertible, Sendable {
    case missingAPIKey
    case apiCallFailed(statusCode: Int, body: String)
    case maxRetriesExceeded(attempts: Int)
    case buildCommandFailed(exitCode: Int32, output: String)
    case noFixProduced
    case tooManyFixes(count: Int, max: Int)
    case unsupportedSchemaVersion(expected: Int, actual: Int)
    case invalidStructuredOutput(reason: String)
    case validationFailed(failures: [ValidationFailure])
    case invalidFixPath(path: String)
    case emptyFixes
    case emptyFixContent(path: String)
    case duplicateFixPath(path: String)
    case pathOutsideProjectRoot(path: String)
    case failedToWriteFile(path: String, reason: String)
    case compilerErrorsNotFound(path: String)
    case sourceFileNotFound(path: String)

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY not found in environment"
        case .apiCallFailed(let code, let body):
            return "OpenAI API error \(code): \(body.prefix(200))"
        case .maxRetriesExceeded(let attempts):
            return "Executor failed after \(attempts) attempts"
        case .buildCommandFailed(let code, let output):
            return "Build failed (exit \(code)): \(output.prefix(200))"
        case .noFixProduced:
            return "GPT-4.5 returned no fixes"
        case .tooManyFixes(let count, let max):
            return "Structured fix response proposed \(count) fixes, exceeding the maximum of \(max)"
        case .unsupportedSchemaVersion(let expected, let actual):
            return "Structured fix response used schema version \(actual), expected \(expected)"
        case .invalidStructuredOutput(let reason):
            return "Structured fix response was invalid: \(reason.prefix(200))"
        case .validationFailed(let failures):
            let summary = failures
                .prefix(3)
                .map(\.message)
                .joined(separator: "; ")
            return "Structured fix response failed validation: \(summary)"
        case .invalidFixPath(let path):
            return "Structured fix response contained an invalid file path: \(path)"
        case .emptyFixes:
            return "Structured fix response contained no fixes"
        case .emptyFixContent(let path):
            return "Structured fix response contained empty content for: \(path)"
        case .duplicateFixPath(let path):
            return "Structured fix response contained duplicate fixes for: \(path)"
        case .pathOutsideProjectRoot(let path):
            return "Structured fix response tried to modify a path outside the project root: \(path)"
        case .failedToWriteFile(let path, let reason):
            return "Failed to write file at \(path): \(reason)"
        case .compilerErrorsNotFound(let path):
            return "Compiler errors file not found: \(path)"
        case .sourceFileNotFound(let path):
            return "Source file not found: \(path)"
        }
    }

    var isRecoverableFixGenerationFailure: Bool {
        switch self {
        case .unsupportedSchemaVersion,
             .tooManyFixes,
             .invalidStructuredOutput,
             .invalidFixPath,
             .emptyFixes,
             .emptyFixContent,
             .duplicateFixPath,
             .pathOutsideProjectRoot,
             .noFixProduced:
            return true
        default:
            return false
        }
    }
}

// MARK: - Fix Types

public struct ValidationFailure: Codable, Sendable, Equatable {
    public let type: String
    public let message: String
    public let path: String?
    public let fixID: String?

    public init(type: String, message: String, path: String? = nil, fixID: String? = nil) {
        self.type = type
        self.message = message
        self.path = path
        self.fixID = fixID
    }
}

public struct FileFix: Codable, Sendable, Equatable {
    public let id: String
    public let filePath: String
    public let content: String

    public init(id: String = "", filePath: String, content: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filePath = filePath
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.filePath = try container.decode(String.self, forKey: .filePath)
        self.content = try container.decode(String.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filePath, forKey: .filePath)
        try container.encode(content, forKey: .content)
    }
}

public struct FixResponse: Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let fixes: [FileFix]

    public init(version: Int = FixResponse.currentVersion, fixes: [FileFix]) {
        self.version = version
        self.fixes = fixes
    }
}

public enum ExecutorStatus: String, Codable, Sendable {
    case fixed
    case failed
    case noErrors
}

struct FixResponseValidationResult: Sendable {
    let canonicalResponse: FixResponse
    let response: FixResponse?
    let validFixes: [FileFix]
    let failures: [ValidationFailure]

    var isValid: Bool {
        response != nil && failures.isEmpty
    }
}

enum FixResponseGuardrails {

    static let defaultMaxFixCount = 20

    static func validate(
        _ response: FixResponse,
        projectRoot: String,
        maxFixCount: Int = defaultMaxFixCount
    ) throws -> FixResponse {
        let result = validationResult(
            for: response,
            projectRoot: projectRoot,
            maxFixCount: maxFixCount
        )
        if let validatedResponse = result.response {
            return validatedResponse
        }

        guard let firstFailure = result.failures.first else {
            throw ExecutorError.invalidStructuredOutput(reason: "Structured fix response was invalid.")
        }

        throw executorError(for: firstFailure)
    }

    static func validationResult(
        for response: FixResponse,
        projectRoot: String,
        maxFixCount: Int = defaultMaxFixCount
    ) -> FixResponseValidationResult {
        var failures: [ValidationFailure] = []
        var canonicalFixes: [FileFix] = []

        if response.version != FixResponse.currentVersion {
            failures.append(
                ValidationFailure(
                    type: "unsupported_schema_version",
                    message: "Structured response used schema version \(response.version). Expected version \(FixResponse.currentVersion).",
                    path: String(response.version)
                )
            )
        }

        if response.fixes.count > maxFixCount {
            failures.append(
                ValidationFailure(
                    type: "too_many_changes",
                    message: "The response proposed \(response.fixes.count) fixes. Return no more than \(maxFixCount) fixes.",
                    path: "\(response.fixes.count):\(maxFixCount)"
                )
            )
        }

        if response.fixes.isEmpty {
            failures.append(
                ValidationFailure(
                    type: "empty_fixes",
                    message: "The response did not include any fixes. Return at least one file fix."
                )
            )
        }

        let normalizedRoot = normalizedProjectRoot(projectRoot)
        var seenFixIDs = Set<String>()
        var seenResolvedPaths = Set<String>()
        var validatedFixes: [FileFix] = []
        validatedFixes.reserveCapacity(response.fixes.count)

        for (index, fix) in response.fixes.enumerated() {
            let canonicalID = canonicalFixID(fix.id, index: index + 1)
            let trimmedPath = fix.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasBlankPath = trimmedPath.isEmpty
            let hasBlankContent = fix.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let canonicalFix = FileFix(id: canonicalID, filePath: trimmedPath, content: fix.content)
            canonicalFixes.append(canonicalFix)
            let hasDuplicateID = !seenFixIDs.insert(canonicalID).inserted

            if hasDuplicateID {
                failures.append(
                    ValidationFailure(
                        type: "duplicate_fix_id",
                        message: "Each fix must use a unique id. Duplicate id detected: \(canonicalID)",
                        fixID: canonicalID
                    )
                )
            }

            if hasBlankPath {
                failures.append(
                    ValidationFailure(
                        type: "invalid_path",
                        message: "Each fix must include a non-empty file path.",
                        path: fix.filePath,
                        fixID: canonicalID
                    )
                )
            }

            if hasBlankContent {
                failures.append(
                    ValidationFailure(
                        type: "empty_content",
                        message: "Each fix must include complete non-empty file content.",
                        path: hasBlankPath ? nil : trimmedPath,
                        fixID: canonicalID
                    )
                )
            }

            guard !hasBlankPath else { continue }

            do {
                let resolvedPath = try resolvedPath(for: trimmedPath, projectRoot: normalizedRoot)
                guard seenResolvedPaths.insert(resolvedPath).inserted else {
                    failures.append(
                        ValidationFailure(
                            type: "duplicate_path",
                            message: "Each fix must use a unique file path. Duplicate path detected: \(trimmedPath)",
                            path: trimmedPath,
                            fixID: canonicalID
                        )
                    )
                    continue
                }

                if !hasBlankContent, !hasDuplicateID {
                    validatedFixes.append(FileFix(id: canonicalID, filePath: trimmedPath, content: fix.content))
                }
            } catch let error as ExecutorError {
                failures.append(validationFailure(for: error, fixID: canonicalID))
            } catch {
                failures.append(
                    ValidationFailure(
                        type: "invalid_fix",
                        message: error.localizedDescription,
                        path: trimmedPath,
                        fixID: canonicalID
                    )
                )
            }
        }

        if failures.isEmpty {
            return FixResponseValidationResult(
                canonicalResponse: FixResponse(version: response.version, fixes: canonicalFixes),
                response: FixResponse(version: response.version, fixes: validatedFixes),
                validFixes: validatedFixes,
                failures: []
            )
        }

        return FixResponseValidationResult(
            canonicalResponse: FixResponse(version: response.version, fixes: canonicalFixes),
            response: nil,
            validFixes: validatedFixes,
            failures: failures
        )
    }

    static func resolvedPath(for filePath: String, projectRoot: String) throws -> String {
        let normalizedRoot = normalizedProjectRoot(projectRoot)
        let rootURL = URL(fileURLWithPath: normalizedRoot)

        let resolvedURL: URL
        if filePath.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: filePath)
        } else {
            resolvedURL = rootURL.appendingPathComponent(filePath)
        }

        let standardizedURL = resolvedURL.standardizedFileURL
        let resolvedParentURL = standardizedURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let resolvedPath = resolvedParentURL
            .appendingPathComponent(standardizedURL.lastPathComponent)
            .standardizedFileURL
            .path

        guard resolvedPath == normalizedRoot || resolvedPath.hasPrefix(normalizedRoot + "/") else {
            throw ExecutorError.pathOutsideProjectRoot(path: filePath)
        }

        return resolvedPath
    }

    private static func normalizedProjectRoot(_ projectRoot: String) -> String {
        URL(fileURLWithPath: projectRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func canonicalFixID(_ rawID: String, index: Int) -> String {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "fix_\(index)" : trimmed
    }

    private static func validationFailure(
        for error: ExecutorError,
        fixID: String? = nil
    ) -> ValidationFailure {
        switch error {
        case .tooManyFixes(let count, let max):
            return ValidationFailure(
                type: "too_many_changes",
                message: "The response proposed \(count) fixes. Return no more than \(max) fixes.",
                path: "\(count):\(max)"
            )
        case .unsupportedSchemaVersion(let expected, let actual):
            return ValidationFailure(
                type: "unsupported_schema_version",
                message: "Structured response used schema version \(actual). Expected version \(expected).",
                fixID: fixID
            )
        case .invalidFixPath(let path):
            return ValidationFailure(
                type: "invalid_path",
                message: "Each fix must include a non-empty file path.",
                path: path,
                fixID: fixID
            )
        case .emptyFixes:
            return ValidationFailure(
                type: "empty_fixes",
                message: "The response did not include any fixes. Return at least one file fix."
            )
        case .emptyFixContent(let path):
            return ValidationFailure(
                type: "empty_content",
                message: "Each fix must include complete non-empty file content.",
                path: path,
                fixID: fixID
            )
        case .duplicateFixPath(let path):
            return ValidationFailure(
                type: "duplicate_path",
                message: "Each fix must use a unique file path. Duplicate path detected: \(path)",
                path: path,
                fixID: fixID
            )
        case .pathOutsideProjectRoot(let path):
            return ValidationFailure(
                type: "out_of_root",
                message: "File path is outside the project root: \(path)",
                path: path,
                fixID: fixID
            )
        case .invalidStructuredOutput(let reason):
            return ValidationFailure(
                type: "invalid_structured_output",
                message: reason,
                fixID: fixID
            )
        default:
            return ValidationFailure(
                type: "validation_error",
                message: String(describing: error),
                fixID: fixID
            )
        }
    }

    private static func executorError(for failure: ValidationFailure) -> ExecutorError {
        switch failure.type {
        case "too_many_changes":
            let parts = (failure.path ?? "").split(separator: ":")
            let count = parts.first.flatMap { Int($0) } ?? 0
            let max = parts.dropFirst().first.flatMap { Int($0) } ?? defaultMaxFixCount
            return .tooManyFixes(count: count, max: max)
        case "unsupported_schema_version":
            let actualVersion = failure.path.flatMap(Int.init) ?? FixResponse.currentVersion
            return .unsupportedSchemaVersion(expected: FixResponse.currentVersion, actual: actualVersion)
        case "invalid_path":
            return .invalidFixPath(path: failure.path ?? "")
        case "empty_fixes":
            return .emptyFixes
        case "empty_content":
            return .emptyFixContent(path: failure.path ?? "")
        case "duplicate_path":
            return .duplicateFixPath(path: failure.path ?? "")
        case "out_of_root":
            return .pathOutsideProjectRoot(path: failure.path ?? "")
        default:
            return .invalidStructuredOutput(reason: failure.message)
        }
    }
}
