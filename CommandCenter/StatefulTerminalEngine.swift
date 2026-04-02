import Foundation

actor StatefulTerminalEngine {

    static let shared = StatefulTerminalEngine()

    private enum OutputSource {
        case stdout
        case stderr
    }

    private struct ActiveCommand {
        let delimiter: String
        var continuation: AsyncStream<String>.Continuation?
    }

    private enum ShellError: LocalizedError {
        case shuttingDown
        case failedToLaunch(String)
        case stdinUnavailable

        var errorDescription: String? {
            switch self {
            case .shuttingDown:
                return "Persistent shell is shutting down."
            case .failedToLaunch(let description):
                return "Failed to launch persistent shell: \(description)"
            case .stdinUnavailable:
                return "Persistent shell stdin is unavailable."
            }
        }
    }

    private let shellPath = "/bin/zsh"
    private let delimiterPrefix = "DARK_FACTORY_EOF"

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var activeCommand: ActiveCommand?
    private var queuedWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCompletedExitStatus: Int?
    private var isShuttingDown = false

    func bootstrap() async {
        _ = try? ensureShellProcess()
    }

    func execute(_ command: String) async -> AsyncStream<String> {
        if activeCommand != nil {
            await waitForAvailableSlot()
        }

        do {
            try ensureShellProcess()
        } catch {
            return Self.errorStream(message: "[ERROR] \(error.localizedDescription)")
        }

        let delimiter = "\(delimiterPrefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let stream = AsyncStream<String>.makeStream()

        stream.continuation.onTermination = { @Sendable _ in
            Task {
                await StatefulTerminalEngine.shared.handleConsumerTermination(for: delimiter)
            }
        }

        activeCommand = ActiveCommand(
            delimiter: delimiter,
            continuation: stream.continuation
        )
        lastCompletedExitStatus = nil

        do {
            try writeToShell(Self.commandEnvelope(for: command, delimiter: delimiter))
        } catch {
            stream.continuation.yield("[ERROR] \(error.localizedDescription)")
            stream.continuation.finish()
            activeCommand = nil
            resumeNextWaiterIfNeeded()
        }

        return stream.stream
    }

    func lastExitStatus() -> Int? {
        lastCompletedExitStatus
    }

    func interruptActiveCommand() async {
        guard !isShuttingDown else { return }
        guard let stdinHandle else { return }

        do {
            try stdinHandle.write(contentsOf: Data([0x03]))
        } catch {
            yieldToActiveCommand("[ERROR] Failed to interrupt shell command: \(error.localizedDescription)")
        }
    }

    func terminate() async {
        isShuttingDown = true

        let activeContinuation = activeCommand?.continuation
        activeCommand = nil
        activeContinuation?.finish()

        let waiters = queuedWaiters
        queuedWaiters.removeAll()
        waiters.forEach { $0.resume() }

        clearReadabilityHandlers()

        if let stdinHandle {
            try? stdinHandle.write(contentsOf: Data("exit\n".utf8))
            try? stdinHandle.close()
        }
        try? stdoutHandle?.close()
        try? stderrHandle?.close()

        if let process, process.isRunning {
            process.terminate()
        }

        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
    }

    private func waitForAvailableSlot() async {
        guard activeCommand != nil else { return }
        await withCheckedContinuation { continuation in
            queuedWaiters.append(continuation)
        }
    }

    private func ensureShellProcess() throws {
        if isShuttingDown {
            throw ShellError.shuttingDown
        }

        if let process, process.isRunning {
            return
        }

        clearReadabilityHandlers()

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment
        process.terminationHandler = { process in
            Task {
                await StatefulTerminalEngine.shared.handleShellTermination(status: process.terminationStatus)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task {
                    await StatefulTerminalEngine.shared.flushBufferedOutput(from: .stdout)
                }
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            Task {
                await StatefulTerminalEngine.shared.handleOutputChunk(chunk, from: .stdout)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                Task {
                    await StatefulTerminalEngine.shared.flushBufferedOutput(from: .stderr)
                }
                return
            }

            let chunk = String(decoding: data, as: UTF8.self)
            Task {
                await StatefulTerminalEngine.shared.handleOutputChunk(chunk, from: .stderr)
            }
        }

        do {
            try process.run()
        } catch {
            clearReadabilityHandlers(for: stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading)
            throw ShellError.failedToLaunch(error.localizedDescription)
        }

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
    }

    private func writeToShell(_ command: String) throws {
        guard let stdinHandle else {
            throw ShellError.stdinUnavailable
        }

        try stdinHandle.write(contentsOf: Data(command.utf8))
    }

    private func handleOutputChunk(_ chunk: String, from source: OutputSource) {
        switch source {
        case .stdout:
            stdoutBuffer.append(chunk)
            consumeBufferedLines(from: &stdoutBuffer, source: .stdout)
        case .stderr:
            stderrBuffer.append(chunk)
            consumeBufferedLines(from: &stderrBuffer, source: .stderr)
        }
    }

    private func flushBufferedOutput(from source: OutputSource) {
        switch source {
        case .stdout:
            flushTrailingBuffer(&stdoutBuffer, source: .stdout)
        case .stderr:
            flushTrailingBuffer(&stderrBuffer, source: .stderr)
        }
    }

    private func consumeBufferedLines(from buffer: inout String, source: OutputSource) {
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
            handleOutputLine(line, from: source)
        }
    }

    private func flushTrailingBuffer(_ buffer: inout String, source: OutputSource) {
        let trailing = buffer.trimmingCharacters(in: .newlines)
        buffer.removeAll(keepingCapacity: false)

        guard !trailing.isEmpty else { return }
        handleOutputLine(trailing, from: source)
    }

    private func handleOutputLine(_ rawLine: String, from source: OutputSource) {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        guard let activeCommand else { return }

        if let exitStatus = parseDelimiter(line, expected: activeCommand.delimiter) {
            lastCompletedExitStatus = exitStatus
            finishActiveCommand()
            return
        }

        switch source {
        case .stdout:
            activeCommand.continuation?.yield(line)
        case .stderr:
            activeCommand.continuation?.yield("[ERROR] \(line)")
        }
    }

    private func finishActiveCommand() {
        activeCommand?.continuation?.finish()
        activeCommand = nil
        resumeNextWaiterIfNeeded()
    }

    private func handleConsumerTermination(for delimiter: String) {
        guard var activeCommand, activeCommand.delimiter == delimiter else { return }
        activeCommand.continuation = nil
        self.activeCommand = activeCommand
    }

    private func handleShellTermination(status: Int32) {
        clearReadabilityHandlers()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        process = nil

        flushBufferedOutput(from: .stdout)
        flushBufferedOutput(from: .stderr)

        if !isShuttingDown {
            yieldToActiveCommand("[ERROR] Persistent shell exited with status \(status).")
        }

        activeCommand?.continuation?.finish()
        activeCommand = nil
        resumeNextWaiterIfNeeded()
    }

    private func yieldToActiveCommand(_ line: String) {
        activeCommand?.continuation?.yield(line)
    }

    private func parseDelimiter(_ line: String, expected delimiter: String) -> Int? {
        let prefix = "\(delimiter):"
        guard line.hasPrefix(prefix) else { return nil }
        let suffix = line.dropFirst(prefix.count)
        return Int(suffix)
    }

    private func resumeNextWaiterIfNeeded() {
        guard !queuedWaiters.isEmpty else { return }
        let waiter = queuedWaiters.removeFirst()
        waiter.resume()
    }

    private func clearReadabilityHandlers() {
        clearReadabilityHandlers(for: stdoutHandle, stderrHandle)
    }

    private func clearReadabilityHandlers(for stdout: FileHandle?, _ stderr: FileHandle?) {
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
    }

    private static func commandEnvelope(for command: String, delimiter: String) -> String {
        """
        \(command)
        printf '%s:%d\n' '\(delimiter)' $?
        
        """
    }

    private static func errorStream(message: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield(message)
            continuation.finish()
        }
    }
}
