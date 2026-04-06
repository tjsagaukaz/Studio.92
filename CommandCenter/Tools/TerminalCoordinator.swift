// TerminalCoordinator.swift
// Studio.92 — Command Center
// Terminal coordination and Fastlane deployment — extracted from AgenticBridge.swift

import Foundation

// MARK: - Fastlane Deployment Runner

actor FastlaneDeploymentRunner {

    static let shared = FastlaneDeploymentRunner()

    private var activeProcess: Process?

    func run(
        projectRoot: URL,
        lane: String,
        command: String,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                var outputLines: [String] = []
                var stdoutBuffer = ""
                var stderrBuffer = ""
                let lock = NSLock()

                func emitBufferedLines(from buffer: inout String, isError: Bool) {
                    while let newlineIndex = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newlineIndex]).trimmingCharacters(in: .newlines)
                        buffer = String(buffer[buffer.index(after: newlineIndex)...])
                        guard !line.isEmpty else { continue }
                        let presented = isError ? "[ERROR] \(line)" : line
                        lock.lock()
                        outputLines.append(presented)
                        lock.unlock()
                        progress(.output(presented))
                    }
                }

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = projectRoot
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.environment = ProcessInfo.processInfo.environment

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stdoutBuffer += chunk
                    emitBufferedLines(from: &stdoutBuffer, isError: false)
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    stderrBuffer += chunk
                    emitBufferedLines(from: &stderrBuffer, isError: true)
                }

                Task {
                    await self?.setActiveProcess(process)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("Failed to launch fastlane \(lane): \(error.localizedDescription)", true))
                    return
                }

                // Timeout watchdog: terminate if fastlane hangs longer than 10 minutes.
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 600)
                timer.setEventHandler {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                emitBufferedLines(from: &stdoutBuffer, isError: false)
                emitBufferedLines(from: &stderrBuffer, isError: true)

                Task {
                    await self?.clearActiveProcess()
                }

                lock.lock()
                let combined = outputLines.joined(separator: "\n")
                lock.unlock()

                let status = process.terminationStatus
                let summary = status == 0
                    ? "Fastlane \(lane) completed successfully."
                    : "Fastlane \(lane) failed with exit code \(status)."
                let result = combined.isEmpty ? summary : "\(summary)\n\n\(combined)"
                continuation.resume(returning: (result, status != 0))
            }
        }
    }

    func cancel() {
        activeProcess?.terminate()
        activeProcess = nil
    }

    private func setActiveProcess(_ process: Process) {
        activeProcess = process
    }

    private func clearActiveProcess() {
        activeProcess = nil
    }
}

// MARK: - Shell Command Lifecycle

actor ShellCommandLifecycle {
    private var finished = false
    private var timedOut = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }

    func markTimedOut() {
        timedOut = true
    }

    func didTimeout() -> Bool {
        timedOut
    }
}

// MARK: - Terminal Coordinator

actor TerminalCoordinator {

    private struct FunctionCall {
        let callID: String
        let name: String
        let arguments: String
    }

    private struct ResponseEnvelope {
        let id: String
        let outputItems: [[String: Any]]

        var functionCalls: [FunctionCall] {
            outputItems.compactMap { item in
                guard (item["type"] as? String) == "function_call",
                      let callID = item["call_id"] as? String,
                      let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String else {
                    return nil
                }
                return FunctionCall(callID: callID, name: name, arguments: arguments)
            }
        }

        var textOutput: String {
            outputItems
                .compactMap { item -> String? in
                    guard (item["type"] as? String) == "message",
                          let content = item["content"] as? [[String: Any]] else {
                        return nil
                    }

                    let fragments = content.compactMap { fragment -> String? in
                        guard (fragment["type"] as? String) == "output_text" else { return nil }
                        return fragment["text"] as? String
                    }

                    guard !fragments.isEmpty else { return nil }
                    return fragments.joined()
                }
                .joined(separator: "\n")
        }
    }

    private struct ShellCapture {
        let output: String
        let exitStatus: Int
        let didTimeout: Bool
    }

    private enum CoordinatorError: LocalizedError {
        case invalidResponse
        case api(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Terminal coordinator returned an invalid response."
            case .api(let statusCode, let body):
                return openAIAPIErrorSummary(statusCode: statusCode, body: body)
            }
        }
    }

    private let apiKey: String
    private let projectRoot: URL
    private let session: URLSession

    private static let responsesURL = StudioAPIConfig.openAIResponsesURL
    private static let modelCandidates = ["gpt-5.4-mini", "gpt-5.4", "gpt-5.4-nano"] + openAIBroadFallbackModels

    init(apiKey: String, projectRoot: URL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.projectRoot = projectRoot
        self.session = session
    }

    func run(
        objective: String,
        context: String?,
        startingCommand: String?,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async throws -> (String, Bool) {
        await primeProjectRoot()

        var previousResponseID: String?
        var pendingInput: [Any] = [Self.initialInput(
            objective: objective,
            context: context,
            startingCommand: startingCommand,
            projectRoot: projectRoot.path
        )]

        for _ in 0..<8 {
            let response = try await createResponse(
                input: pendingInput,
                previousResponseID: previousResponseID
            )
            previousResponseID = response.id

            let functionCalls = response.functionCalls
            if functionCalls.isEmpty {
                let summary = response.textOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                return (summary.isEmpty ? "Terminal session complete." : summary, false)
            }

            var functionOutputs: [[String: Any]] = []

            for call in functionCalls {
                guard call.name == "run_shell_command" else {
                    functionOutputs.append(
                        Self.functionCallOutput(
                            callID: call.callID,
                            output: "Unsupported function: \(call.name)"
                        )
                    )
                    continue
                }

                let payload = Self.parseJSONObject(from: call.arguments) ?? [:]
                let command = ((payload["command"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let callTimeout = min(max(payload["timeout_seconds"] as? Int ?? timeoutSeconds, 1), 120)

                guard !command.isEmpty else {
                    functionOutputs.append(
                        Self.functionCallOutput(
                            callID: call.callID,
                            output: "Missing required command argument."
                        )
                    )
                    continue
                }

                progress(.command(command))
                progress(.output("$ \(command)"))

                let shellCapture = await executeShellCommand(
                    command,
                    timeoutSeconds: callTimeout,
                    progress: progress
                )

                let shellOutput = Self.serializedToolOutput(
                    command: command,
                    output: shellCapture.output,
                    exitStatus: shellCapture.exitStatus,
                    didTimeout: shellCapture.didTimeout
                )
                functionOutputs.append(
                    Self.functionCallOutput(
                        callID: call.callID,
                        output: shellOutput
                    )
                )
            }

            pendingInput = functionOutputs
        }

        return ("Terminal session reached the maximum number of command turns before finishing.", true)
    }

    private func createResponse(
        input: [Any],
        previousResponseID: String?
    ) async throws -> ResponseEnvelope {
        var lastError: Error = CoordinatorError.invalidResponse

        for model in Self.modelCandidates {
            do {
                return try await createResponse(
                    model: model,
                    input: input,
                    previousResponseID: previousResponseID
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func createResponse(
        model: String,
        input: [Any],
        previousResponseID: String?
    ) async throws -> ResponseEnvelope {
        var body: [String: Any] = [
            "model": model,
            "instructions": Self.instructions(projectRoot: projectRoot.path),
            "input": input,
            "tools": [Self.runShellTool],
            "max_output_tokens": 1_200
        ]
        if openAIModelSupportsReasoning(model) {
            body["reasoning"] = ["effort": "none"]
            body["text"] = ["verbosity": "low"]
        }
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = previousResponseID
        }

        var request = URLRequest(url: Self.responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performOpenAIDataRequest(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let outputItems = json["output"] as? [[String: Any]] else {
            throw CoordinatorError.invalidResponse
        }

        return ResponseEnvelope(id: id, outputItems: outputItems)
    }

    private func performOpenAIDataRequest(_ request: URLRequest) async throws -> Data {
        var attempt = 0

        while true {
            attempt += 1

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CoordinatorError.invalidResponse
            }

            guard http.statusCode == 200 else {
                let bodyText = String(decoding: data, as: UTF8.self)

                if openAIShouldRetry(statusCode: http.statusCode, attempt: attempt) {
                    let retryDelay = openAIRetryDelay(attempt: attempt, response: http)
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    continue
                }

                throw CoordinatorError.api(statusCode: http.statusCode, body: bodyText)
            }

            return data
        }
    }

    private func primeProjectRoot() async {
        let bootstrapCommand = "cd \(Self.shellQuoted(projectRoot.path))"
        let stream = await StatefulTerminalEngine.shared.execute(bootstrapCommand)
        for await _ in stream {}
    }

    private func executeShellCommand(
        _ command: String,
        timeoutSeconds: Int,
        progress: @escaping @Sendable (ToolProgress) -> Void
    ) async -> ShellCapture {
        let commandID = UUID().uuidString
        SimulatorShellCommandNotifier.commandDidStart(
            id: commandID,
            command: command,
            projectRoot: projectRoot.path
        )

        let stream = await StatefulTerminalEngine.shared.execute(command)
        let lifecycle = ShellCommandLifecycle()

        let consumer = Task<[String], Never> {
            var lines: [String] = []
            for await line in stream {
                progress(.output(line))
                lines.append(line)
            }
            await lifecycle.markFinished()
            return lines
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            if !(await lifecycle.isFinished()) {
                await lifecycle.markTimedOut()
                await StatefulTerminalEngine.shared.interruptActiveCommand()
            }
        }

        let lines = await consumer.value
        timeoutTask.cancel()

        let capture = ShellCapture(
            output: lines.joined(separator: "\n"),
            exitStatus: await StatefulTerminalEngine.shared.lastExitStatus() ?? 0,
            didTimeout: await lifecycle.didTimeout()
        )

        SimulatorShellCommandNotifier.commandDidFinish(
            id: commandID,
            command: command,
            projectRoot: projectRoot.path,
            output: capture.output,
            exitStatus: Int32(capture.exitStatus)
        )

        return capture
    }

    private static var runShellTool: [String: Any] {
        [
            "type": "function",
            "name": "run_shell_command",
            "description": "Execute a non-destructive shell command in the project workspace and return its output.",
            "strict": true,
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The shell command to run."],
                    "timeout_seconds": ["type": "integer", "description": "Command timeout in seconds (max 120)."],
                    "reason": ["type": "string", "description": "Why this command is the right next step."]
                ] as [String: Any],
                "required": ["command"],
                "additionalProperties": false
            ] as [String: Any]
        ]
    }

    private static func instructions(projectRoot: String) -> String {
        """
        You are the terminal execution specialist inside Studio.92.

        You control a local persistent zsh shell through the run_shell_command tool.
        The shell has already been positioned at the project root for this session: \(projectRoot)

        Work like a calm senior engineer at the terminal:
        - Use shell commands for inspection, builds, tests, git status, and targeted verification.
        - Prefer the smallest useful sequence of commands and inspect before making conclusions.
        - Keep moving; you do not need to narrate every step.
        - Do not edit files through the shell. Other tools handle file changes.
        - Avoid destructive commands, including rm -rf, git reset --hard, git checkout --, sudo, or broad deletes.
        - Stop once you have enough evidence to answer the objective clearly.
        - Return a short grounded summary of what you verified, what failed, and the next best step if relevant.
        """
    }

    private static func initialInput(
        objective: String,
        context: String?,
        startingCommand: String?,
        projectRoot: String
    ) -> [String: Any] {
        var text = """
        Objective:
        \(objective)

        Project root:
        \(projectRoot)
        """

        if let context, !context.isEmpty {
            text += "\n\nRelevant context:\n\(context)"
        }

        if let startingCommand, !startingCommand.isEmpty {
            text += "\n\nSuggested first command:\n\(startingCommand)"
        }

        return [
            "role": "user",
            "content": [
                [
                    "type": "input_text",
                    "text": text
                ]
            ]
        ]
    }

    private static func functionCallOutput(callID: String, output: String) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ]
    }

    private static func serializedToolOutput(
        command: String,
        output: String,
        exitStatus: Int,
        didTimeout: Bool
    ) -> String {
        var payload: [String: Any] = [
            "command": command,
            "exit_status": exitStatus,
            "timed_out": didTimeout
        ]

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            payload["output"] = "(no output)"
        } else if trimmed.count > 20_000 {
            payload["output"] = String(trimmed.prefix(20_000)) + "\n[Truncated]"
        } else {
            payload["output"] = trimmed
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "command=\(command)\nexit_status=\(exitStatus)\ntimed_out=\(didTimeout)\noutput=\(trimmed)"
        }

        return text
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

}
