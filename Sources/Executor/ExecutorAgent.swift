// ExecutorAgent.swift
// Studio.92 — Executor
// OpenAI-powered build-repair loop.

import CryptoKit
import Foundation

// MARK: - Config

public struct ExecutorConfig: Sendable {
    public let maxRetries: Int
    public let maxFixesPerResponse: Int
    public let projectRoot: String
    public let compilerErrorsPath: String?
    public let model: String
    public let verbose: Bool
    public let buildWorkspace: String?
    public let buildScheme: String?

    public init(
        maxRetries:         Int     = 3,
        maxFixesPerResponse: Int    = 20,
        projectRoot:        String,
        compilerErrorsPath: String? = nil,
        model:              String  = OpenAIModel.gpt45.rawValue,
        verbose:            Bool    = false,
        buildWorkspace:     String? = nil,
        buildScheme:        String? = nil
    ) {
        self.maxRetries         = maxRetries
        self.maxFixesPerResponse = max(1, maxFixesPerResponse)
        self.projectRoot        = projectRoot
        self.compilerErrorsPath = compilerErrorsPath
        self.model              = model
        self.verbose            = verbose
        self.buildWorkspace     = buildWorkspace ?? ProcessInfo.processInfo.environment["STUDIO92_WORKSPACE"]
        self.buildScheme        = buildScheme ?? ProcessInfo.processInfo.environment["STUDIO92_SCHEME"]
    }
}

// MARK: - Result

public struct ExecutorResult: Codable, Sendable {
    public let status: ExecutorStatus
    public let attemptsUsed: Int
    public let filesModified: [String]
    public let finalBuildOutput: String
    public let timestamp: String

    public init(
        status:           ExecutorStatus,
        attemptsUsed:     Int,
        filesModified:    [String],
        finalBuildOutput: String
    ) {
        self.status           = status
        self.attemptsUsed     = attemptsUsed
        self.filesModified    = filesModified
        self.finalBuildOutput = finalBuildOutput

        let formatter = ISO8601DateFormatter()
        self.timestamp = formatter.string(from: Date())
    }
}

private struct ExecutionSummary: Sendable {
    var total: Int = 0
    var applied: Int = 0
    var skipped: Int = 0
    var failed: Int = 0

    func delta(since previous: ExecutionSummary) -> ExecutionSummary {
        ExecutionSummary(
            total: total - previous.total,
            applied: applied - previous.applied,
            skipped: skipped - previous.skipped,
            failed: failed - previous.failed
        )
    }
}

private enum FixApplicationDisposition: String, Sendable {
    case applied
    case skippedDuplicate
    case skippedUnchanged
}

private struct FixApplicationOutcome: Sendable {
    let path: String
    let disposition: FixApplicationDisposition
    let appliedFingerprint: String?
}

private struct AttemptFileSnapshot: Sendable {
    let path: String
    let existed: Bool
    let originalData: Data?
}

// MARK: - ExecutorAgent

public actor ExecutorAgent {

    private let api: OpenAIAPIClient
    private let config: ExecutorConfig
    private var allModifiedFiles: Set<String> = []
    private var appliedFixFingerprints: Set<String> = []
    private var executionSummary = ExecutionSummary()

    public init(api: OpenAIAPIClient, config: ExecutorConfig) {
        self.api    = api
        self.config = config
    }

    // MARK: - Run

    public func run() async throws -> ExecutorResult {
        // Read initial compiler errors
        let initialErrors = try readCompilerErrors()

        if initialErrors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("No compiler errors found")
            return makeResult(
                status: .noErrors,
                attemptsUsed: 0,
                filesModified: [],
                finalBuildOutput: "No errors"
            )
        }

        var currentErrors = initialErrors

        for attempt in 1...config.maxRetries {
            log("Attempt \(attempt)/\(config.maxRetries)...")
            let summaryAtAttemptStart = executionSummary

            // 1. Parse deduplicated error file paths
            let errorPaths = parseErrorPaths(from: currentErrors)
            log("Found errors in \(errorPaths.count) file(s)")

            // 2. Read source files
            let sourceContext = readSourceFiles(paths: errorPaths)

            // 3. Build prompt
            let userMessage: String
            if attempt == 1 {
                userMessage = """
                ## Compiler Errors
                \(currentErrors)

                ## Source Files
                \(sourceContext)
                """
            } else {
                userMessage = """
                The previous fix did not resolve all errors. Remaining errors:

                ## Compiler Errors
                \(currentErrors)

                ## Source Files
                \(sourceContext)
                """
            }

            // 4. Generate validated structured fixes
            let response: FixResponse
            do {
                response = try await api.generateFixResponse(
                    systemPrompt: ExecutorPersona.system,
                    messages:     [.user(userMessage)],
                    projectRoot:  config.projectRoot,
                    model:        config.model,
                    maxTokens:    4096,
                    temperature:  0.1,
                    maxFixCount:  config.maxFixesPerResponse,
                    logRefinement: config.verbose
                )
            } catch ExecutorError.validationFailed(let failures) {
                log("Structured fix refinement exhausted: \(failures.map(\.message).joined(separator: "; "))")
                return makeResult(
                    status: .failed,
                    attemptsUsed: attempt,
                    filesModified: Array(allModifiedFiles).sorted(),
                    finalBuildOutput: currentErrors
                )
            } catch let error as ExecutorError where error.isRecoverableFixGenerationFailure {
                log("Structured fix response rejected: \(error)")
                if attempt == config.maxRetries {
                    return makeResult(
                        status: .failed,
                        attemptsUsed: attempt,
                        filesModified: Array(allModifiedFiles).sorted(),
                        finalBuildOutput: currentErrors
                    )
                }
                continue
            } catch {
                log("API call failed: \(error)")
                throw error
            }

            logStructuredFixResponse(response)
            let fixes = response.fixes

            // 6. Apply fixes
            try applyFixes(fixes)
            logExecutionSummary(
                label: "Attempt \(attempt)",
                summary: executionSummary.delta(since: summaryAtAttemptStart)
            )

            // 7. Re-run build
            let buildResult = runBuild()

            if buildResult.succeeded {
                log("Build succeeded on attempt \(attempt)")
                return makeResult(
                    status: .fixed,
                    attemptsUsed: attempt,
                    filesModified: Array(allModifiedFiles).sorted(),
                    finalBuildOutput: buildResult.output
                )
            }

            // Build still failing — extract new errors for next attempt
            currentErrors = buildResult.output
            log("Build still failing, \(config.maxRetries - attempt) attempt(s) remaining")
        }

        return makeResult(
            status: .failed,
            attemptsUsed: config.maxRetries,
            filesModified: Array(allModifiedFiles).sorted(),
            finalBuildOutput: currentErrors
        )
    }

    // MARK: - Compiler Error Reading

    private func readCompilerErrors() throws -> String {
        if let path = config.compilerErrorsPath {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ExecutorError.compilerErrorsNotFound(path: path)
            }
            return try String(contentsOfFile: path, encoding: .utf8)
        }

        // Read from stdin
        var lines: [String] = []
        while let line = readLine(strippingNewline: false) {
            lines.append(line)
        }
        return lines.joined()
    }

    // MARK: - Error Path Parsing

    /// Parse file paths from Xcode error output, deduplicated.
    func parseErrorPaths(from errors: String) -> [String] {
        // Match: /path/to/File.swift:42:15: error: ...
        let pattern = #"(/[^\s:]+\.swift):\d+:\d+:\s*error:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(errors.startIndex..., in: errors)
        let matches = regex.matches(in: errors, range: range)

        var paths = Set<String>()
        for match in matches {
            if let pathRange = Range(match.range(at: 1), in: errors) {
                paths.insert(String(errors[pathRange]))
            }
        }

        return paths.sorted()
    }

    // MARK: - Source File Reading

    private func readSourceFiles(paths: [String]) -> String {
        var context = ""
        var totalChars = 0
        let maxChars = 100_000

        for path in paths {
            guard totalChars < maxChars else {
                context += "\n// [Truncated — context limit reached]\n"
                break
            }

            guard FileManager.default.fileExists(atPath: path) else {
                context += "\n// File not found: \(path)\n"
                continue
            }

            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            let header = "\n// === \(path) ===\n"
            context += header + content + "\n"
            totalChars += content.count
        }

        return context
    }

    // MARK: - Fix Application

    private func applyFixes(_ fixes: [FileFix]) throws {
        var snapshots: [String: AttemptFileSnapshot] = [:]
        var appliedFingerprintsThisAttempt = Set<String>()
        var newlyModifiedPathsThisAttempt = Set<String>()

        do {
            for fix in fixes {
                executionSummary.total += 1
                let outcome = try applyFix(fix, snapshots: &snapshots)

                switch outcome.disposition {
                case .applied:
                    executionSummary.applied += 1
                    if allModifiedFiles.insert(outcome.path).inserted {
                        newlyModifiedPathsThisAttempt.insert(outcome.path)
                    }
                    if let fingerprint = outcome.appliedFingerprint {
                        appliedFingerprintsThisAttempt.insert(fingerprint)
                    }
                    log("Applied fix: \(outcome.path)")
                case .skippedDuplicate:
                    executionSummary.skipped += 1
                    log("Skipped duplicate fix: \(outcome.path)")
                case .skippedUnchanged:
                    executionSummary.skipped += 1
                    log("Skipped no-op fix: \(outcome.path)")
                }
            }
        } catch {
            executionSummary.failed += 1
            rollbackAttemptSnapshots(snapshots)
            appliedFixFingerprints.subtract(appliedFingerprintsThisAttempt)
            allModifiedFiles.subtract(newlyModifiedPathsThisAttempt)
            throw error
        }
    }

    private func applyFix(
        _ fix: FileFix,
        snapshots: inout [String: AttemptFileSnapshot]
    ) throws -> FixApplicationOutcome {
        let resolvedPath = try FixResponseGuardrails.resolvedPath(
            for: fix.filePath,
            projectRoot: config.projectRoot
        )
        let url = URL(fileURLWithPath: resolvedPath)
        let fingerprint = fixFingerprint(path: resolvedPath, content: fix.content)

        if appliedFixFingerprints.contains(fingerprint) {
            return FixApplicationOutcome(
                path: resolvedPath,
                disposition: .skippedDuplicate,
                appliedFingerprint: nil
            )
        }

        if let existingContent = try? String(contentsOf: url, encoding: .utf8),
           existingContent == fix.content {
            appliedFixFingerprints.insert(fingerprint)
            return FixApplicationOutcome(
                path: resolvedPath,
                disposition: .skippedUnchanged,
                appliedFingerprint: nil
            )
        }

        if snapshots[resolvedPath] == nil {
            let existed = FileManager.default.fileExists(atPath: resolvedPath)
            let originalData = existed ? try? Data(contentsOf: url) : nil
            snapshots[resolvedPath] = AttemptFileSnapshot(
                path: resolvedPath,
                existed: existed,
                originalData: originalData
            )
        }

        // Ensure directory exists
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try fix.content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ExecutorError.failedToWriteFile(
                path: resolvedPath,
                reason: String(describing: error)
            )
        }

        appliedFixFingerprints.insert(fingerprint)
        return FixApplicationOutcome(
            path: resolvedPath,
            disposition: .applied,
            appliedFingerprint: fingerprint
        )
    }

    private func rollbackAttemptSnapshots(_ snapshots: [String: AttemptFileSnapshot]) {
        guard !snapshots.isEmpty else { return }

        for snapshot in snapshots.values.sorted(by: { $0.path < $1.path }) {
            let url = URL(fileURLWithPath: snapshot.path)

            do {
                if snapshot.existed {
                    guard let originalData = snapshot.originalData else {
                        log("Rollback skipped for \(snapshot.path): original contents unavailable")
                        continue
                    }
                    try originalData.write(to: url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: snapshot.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                log("Rollback failed for \(snapshot.path): \(error)")
            }
        }
    }

    // MARK: - Build

    struct BuildResult {
        let succeeded: Bool
        let output: String
        let exitCode: Int32
    }

    func runBuild() -> BuildResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var args = ["xcodebuild", "build"]

        if let workspace = config.buildWorkspace {
            args += ["-workspace", workspace]
        }
        if let scheme = config.buildScheme {
            args += ["-scheme", scheme]
        }
        args += ["-quiet"]

        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: config.projectRoot)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return BuildResult(succeeded: false, output: "Failed to launch xcodebuild: \(error)", exitCode: -1)
        }

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return BuildResult(
            succeeded: process.terminationStatus == 0,
            output: output,
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Logging

    private func makeResult(
        status: ExecutorStatus,
        attemptsUsed: Int,
        filesModified: [String],
        finalBuildOutput: String
    ) -> ExecutorResult {
        logExecutionSummary(label: "Run", summary: executionSummary)
        return ExecutorResult(
            status: status,
            attemptsUsed: attemptsUsed,
            filesModified: filesModified,
            finalBuildOutput: finalBuildOutput
        )
    }

    private func log(_ message: String) {
        if config.verbose {
            FileHandle.standardError.write(Data("[executor] \(message)\n".utf8))
        }
    }

    private func logStructuredFixResponse(_ response: FixResponse) {
        guard config.verbose else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        if let data = try? encoder.encode(response),
           let json = String(data: data, encoding: .utf8) {
            log("Structured fix response: \(json)")
        } else {
            log("Structured fix response contained \(response.fixes.count) fix(es)")
        }
    }

    private func logExecutionSummary(label: String, summary: ExecutionSummary) {
        guard config.verbose else { return }
        log("\(label) summary: total=\(summary.total) applied=\(summary.applied) skipped=\(summary.skipped) failed=\(summary.failed)")
    }

    private func fixFingerprint(path: String, content: String) -> String {
        let payload = Data("\(path)\u{0}\(content)".utf8)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
