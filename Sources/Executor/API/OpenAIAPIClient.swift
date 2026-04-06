// OpenAIAPIClient.swift
// Studio.92 — Executor
// swift-ai-sdk backed client for OpenAI text and structured generation.

import Foundation
import AISDKProvider
import OpenAIProvider
import SwiftAISDK

public actor OpenAIAPIClient {

    private let apiKey: String
    private let provider: OpenAIProvider

    public init(apiKey: String, session: URLSession = .shared) {
        _ = session
        self.apiKey = apiKey
        self.provider = createOpenAIProvider(settings: .init(apiKey: apiKey))
    }

    /// Initialize from environment variable OPENAI_API_KEY.
    public init(session: URLSession = .shared) throws {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !key.isEmpty else {
            throw ExecutorError.missingAPIKey
        }
        _ = session
        self.apiKey = key
        self.provider = createOpenAIProvider(settings: .init(apiKey: key))
    }

    // MARK: - Public API

    /// Send a text generation request to OpenAI and return a compatibility response.
    public func complete(
        systemPrompt: String,
        messages:      [OpenAIMessage],
        model:         String = OpenAIModel.gpt54.rawValue,
        maxTokens:     Int    = 4096,
        temperature:   Double = 0.1
    ) async throws -> OpenAIResponse {
        do {
            let result = try await generateText(
                model: provider.responses(model),
                system: systemPrompt,
                messages: modelMessages(from: messages),
                settings: CallSettings(
                    maxOutputTokens: maxTokens,
                    temperature: temperature,
                    maxRetries: 0
                )
            )

            let usage = OpenAIUsage(
                prompt_tokens: result.usage.inputTokens ?? 0,
                completion_tokens: result.usage.outputTokens ?? 0,
                total_tokens: result.usage.totalTokens
                    ?? ((result.usage.inputTokens ?? 0) + (result.usage.outputTokens ?? 0))
            )

            let choice = OpenAIChoice(
                index: 0,
                message: OpenAIChoiceMessage(
                    role: OpenAIRole.assistant.rawValue,
                    content: result.text
                ),
                finish_reason: result.finishReason.rawValue
            )

            return OpenAIResponse(
                id: result.response.id,
                choices: [choice],
                model: result.response.modelId,
                usage: usage
            )
        } catch {
            throw normalizedError(error)
        }
    }

    public func generateFixResponse(
        systemPrompt: String,
        messages: [OpenAIMessage],
        projectRoot: String,
        model: String = OpenAIModel.gpt54.rawValue,
        maxTokens: Int = 4096,
        temperature: Double = 0.1,
        maxAttempts: Int = 2,
        maxFixCount: Int = 20,
        logRefinement: Bool = false
    ) async throws -> FixResponse {
        let attemptCount = max(1, maxAttempts)
        var requestMessages = messages
        var latestValidationFailures: [ValidationFailure] = []
        var frozenFixesByID: [String: FileFix] = [:]

        for attempt in 1...attemptCount {
            do {
                let result = try await generateObject(
                    model: provider.responses(model),
                    schema: FixResponse.self,
                    system: systemPrompt,
                    messages: modelMessages(from: requestMessages),
                    schemaName: "fix_response",
                    schemaDescription: "Schema version 1. Complete file replacements that resolve the reported Swift compiler errors.",
                    settings: CallSettings(
                        maxOutputTokens: maxTokens,
                        temperature: temperature,
                        maxRetries: 0
                    )
                )

                let validationResult = FixResponseGuardrails.validationResult(
                    for: result.object,
                    projectRoot: projectRoot,
                    maxFixCount: maxFixCount
                )
                let refinementFailures = preservedFixFailures(
                    in: validationResult.canonicalResponse,
                    frozenFixesByID: frozenFixesByID
                )
                let combinedFailures = validationResult.failures + refinementFailures

                logRefinementAttempt(
                    attempt: attempt,
                    totalAttempts: attemptCount,
                    validCount: validationResult.validFixes.count,
                    invalidCount: combinedFailures.count,
                    frozenCount: frozenFixesByID.count,
                    failures: combinedFailures,
                    enabled: logRefinement
                )

                if combinedFailures.isEmpty, let validatedResponse = validationResult.response {
                    return validatedResponse
                }

                latestValidationFailures = combinedFailures
                guard attempt < attemptCount else {
                    throw ExecutorError.validationFailed(failures: combinedFailures)
                }

                if shouldUpdateFrozenFixes(with: combinedFailures) {
                    for fix in validationResult.validFixes {
                        frozenFixesByID[fix.id] = fix
                    }
                }

                requestMessages = refinementMessages(
                    from: requestMessages,
                    previousResponse: validationResult.canonicalResponse,
                    failures: combinedFailures,
                    preservedValidFixes: frozenFixesByID.values.sorted { $0.id < $1.id },
                    attempt: attempt,
                    totalAttempts: attemptCount,
                    maxFixCount: maxFixCount
                )
                continue
            } catch {
                let normalized = normalizedError(error)
                let shouldRetry = shouldRetryStructuredGeneration(
                    originalError: error,
                    normalizedError: normalized
                )

                guard attempt < attemptCount, shouldRetry else {
                    throw normalized
                }
            }
        }

        if !latestValidationFailures.isEmpty {
            throw ExecutorError.validationFailed(failures: latestValidationFailures)
        }

        throw ExecutorError.invalidStructuredOutput(reason: "Structured fix generation exhausted all attempts.")
    }

    // MARK: - Private

    private func modelMessages(from messages: [OpenAIMessage]) -> [ModelMessage] {
        messages.compactMap { message in
            switch message.role {
            case .system:
                return nil
            case .user:
                return .user(message.content)
            case .assistant:
                return .assistant(message.content)
            }
        }
    }

    private func shouldRetryStructuredGeneration(
        originalError: Error,
        normalizedError: Error
    ) -> Bool {
        if let apiError = originalError as? APICallError {
            return apiError.isRetryable
        }

        if originalError is NoObjectGeneratedError {
            return true
        }

        if let executorError = normalizedError as? ExecutorError {
            return executorError.isRecoverableFixGenerationFailure
        }

        return false
    }

    private func normalizedError(_ error: Error) -> Error {
        if let apiError = error as? APICallError {
            return ExecutorError.apiCallFailed(
                statusCode: apiError.statusCode ?? 0,
                body: apiError.responseBody ?? apiError.message
            )
        }

        if let objectError = error as? NoObjectGeneratedError {
            let reason = objectError.text ?? objectError.message
            return ExecutorError.invalidStructuredOutput(reason: reason)
        }

        if let executorError = error as? ExecutorError {
            return executorError
        }

        return error
    }

    private func refinementMessages(
        from messages: [OpenAIMessage],
        previousResponse: FixResponse,
        failures: [ValidationFailure],
        preservedValidFixes: [FileFix],
        attempt: Int,
        totalAttempts: Int,
        maxFixCount: Int
    ) -> [OpenAIMessage] {
        var refinedMessages = messages

        refinedMessages.append(.assistant(serializedResponse(previousResponse)))
        refinedMessages.append(
            .user(
                refinementUserMessage(
                    failures: failures,
                    preservedValidFixes: preservedValidFixes,
                    attempt: attempt,
                    totalAttempts: totalAttempts,
                    maxFixCount: maxFixCount
                )
            )
        )

        return refinedMessages
    }

    private func serializedResponse(_ response: FixResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let data = try? encoder.encode(response),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return "{\"version\":\(response.version),\"fixes\":[]}"
    }

    private func refinementUserMessage(
        failures: [ValidationFailure],
        preservedValidFixes: [FileFix],
        attempt: Int,
        totalAttempts: Int,
        maxFixCount: Int
    ) -> String {
        let failureLines = failures
            .map { failure in
                let idPrefix = failure.fixID.map { "Fix id=\($0): " } ?? ""
                return "- \(idPrefix)\(failure.message)"
            }
            .joined(separator: "\n")
        let preservedLines = preservedValidFixes
            .map { "- id=\($0.id) path=\($0.filePath)" }
            .joined(separator: "\n")
        let preservedSection = preservedLines.isEmpty
            ? ""
            : """
            Valid fixes to preserve exactly:
            \(preservedLines)

            """
        let finalAttemptLine = attempt + 1 == totalAttempts
            ? "- This is the final attempt. If any item is still uncertain, omit it rather than returning an invalid fix.\n"
            : ""

        return """
        Your previous response had validation issues.

        Keep all valid fixes unchanged.
        Only correct the invalid items listed below.

        Attempt \(attempt) of \(totalAttempts)
        \(preservedSection)Errors:
        \(failureLines)

        Return a corrected JSON response only.
        Requirements:
        - Keep schema version set to 1.
        - Preserve every valid fix exactly as-is, including its id, file path, and content.
        - Use stable unique ids for every fix.
        - When correcting an invalid fix, keep its id the same.
        - Each fix must use a unique file path.
        - Every file path must stay inside the project root.
        - Every fix must include complete non-empty file content.
        - Return no more than \(maxFixCount) fixes.
        \(finalAttemptLine)- Fix only the invalid parts if the other fixes still apply.
        - Do not repeat the same validation mistakes.
        """
    }

    private func preservedFixFailures(
        in response: FixResponse,
        frozenFixesByID: [String: FileFix]
    ) -> [ValidationFailure] {
        guard !frozenFixesByID.isEmpty else { return [] }

        let currentFixesByID = Dictionary(
            response.fixes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var failures: [ValidationFailure] = []

        for frozenFix in frozenFixesByID.values.sorted(by: { $0.id < $1.id }) {
            guard let currentFix = currentFixesByID[frozenFix.id] else {
                failures.append(
                    ValidationFailure(
                        type: "missing_frozen_fix",
                        message: "Previously valid fix must be preserved unchanged.",
                        path: frozenFix.filePath,
                        fixID: frozenFix.id
                    )
                )
                continue
            }

            guard currentFix.filePath == frozenFix.filePath,
                  currentFix.content == frozenFix.content else {
                failures.append(
                    ValidationFailure(
                        type: "modified_frozen_fix",
                        message: "Previously valid fix was modified. Keep valid fixes unchanged.",
                        path: frozenFix.filePath,
                        fixID: frozenFix.id
                    )
                )
                continue
            }
        }

        return failures
    }

    private func shouldUpdateFrozenFixes(with failures: [ValidationFailure]) -> Bool {
        let blockingTypes: Set<String> = [
            "too_many_changes",
            "missing_frozen_fix",
            "modified_frozen_fix"
        ]
        return failures.allSatisfy { !blockingTypes.contains($0.type) }
    }

    private func logRefinementAttempt(
        attempt: Int,
        totalAttempts: Int,
        validCount: Int,
        invalidCount: Int,
        frozenCount: Int,
        failures: [ValidationFailure],
        enabled: Bool
    ) {
        guard enabled else { return }

        let isFinalAttempt = attempt == totalAttempts
        logRefinement(
            "[Refine] attempt=\(attempt) total=\(totalAttempts) valid=\(validCount) invalid=\(invalidCount) frozen=\(frozenCount) final=\(isFinalAttempt)"
        )

        guard !failures.isEmpty else { return }

        let histogram = Dictionary(failures.map { ($0.type, 1) }, uniquingKeysWith: +)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        logRefinement("[Refine] failures: \(histogram)")
    }

    private func logRefinement(_ message: String) {
        FileHandle.standardError.write(Data("[executor] \(message)\n".utf8))
    }
}
