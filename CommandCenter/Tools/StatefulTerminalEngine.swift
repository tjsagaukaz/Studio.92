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
    private var stdoutDecoder = UTF8PipeDecoder()
    private var stderrDecoder = UTF8PipeDecoder()
    private var activeCommand: ActiveCommand?
    private var commandTimeoutTask: Task<Void, Never>?
    private var queuedWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCompletedExitStatus: Int?
    private var isShuttingDown = false

    /// Maximum wall-clock time a single command may run before forced termination.
    private let commandTimeoutSeconds: Int = 120

    /// Safety cap for partial-line buffers. A single line exceeding this
    /// (e.g. binary output, \r-only progress bars) is drained to prevent OOM.
    private let maxLineBufferSize = 512_000 // 512KB

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
        startCommandWatchdog()

        do {
            try writeToShell(Self.commandEnvelope(for: command, delimiter: delimiter))
        } catch {
            cancelCommandWatchdog()
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

            Task {
                await StatefulTerminalEngine.shared.handleRawOutput(data, from: .stdout)
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

            Task {
                await StatefulTerminalEngine.shared.handleRawOutput(data, from: .stderr)
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
        stdoutDecoder = UTF8PipeDecoder()
        stderrDecoder = UTF8PipeDecoder()
    }

    private func writeToShell(_ command: String) throws {
        guard let stdinHandle else {
            throw ShellError.stdinUnavailable
        }

        try stdinHandle.write(contentsOf: Data(command.utf8))
    }

    /// Decode raw pipe bytes through the UTF-8 stream decoder to avoid corrupting
    /// multi-byte characters split across availableData deliveries.
    private func handleRawOutput(_ data: Data, from source: OutputSource) {
        let decoder = source == .stdout ? stdoutDecoder : stderrDecoder
        guard let chunk = decoder.append(data) else { return }
        handleOutputChunk(chunk, from: source)
    }

    private func handleOutputChunk(_ chunk: String, from source: OutputSource) {
        switch source {
        case .stdout:
            stdoutBuffer.append(chunk)
            if stdoutBuffer.utf8.count > maxLineBufferSize {
                stdoutBuffer.removeAll(keepingCapacity: false)
            }
            consumeBufferedLines(from: &stdoutBuffer, source: .stdout)
        case .stderr:
            stderrBuffer.append(chunk)
            if stderrBuffer.utf8.count > maxLineBufferSize {
                stderrBuffer.removeAll(keepingCapacity: false)
            }
            consumeBufferedLines(from: &stderrBuffer, source: .stderr)
        }
    }

    private func flushBufferedOutput(from source: OutputSource) {
        // Flush any incomplete UTF-8 bytes held by the decoder.
        let decoder = source == .stdout ? stdoutDecoder : stderrDecoder
        if let tail = decoder.flush() {
            handleOutputChunk(tail, from: source)
        }

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
        cancelCommandWatchdog()
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
        cancelCommandWatchdog()
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

    // MARK: - Command Timeout Watchdog

    private func startCommandWatchdog() {
        cancelCommandWatchdog()
        let seconds = commandTimeoutSeconds
        commandTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return // Cancelled — command completed before timeout.
            }
            await self?.handleCommandTimeout()
        }
    }

    private func cancelCommandWatchdog() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
    }

    private nonisolated func handleCommandTimeout() async {
        await handleCommandTimeoutIsolated()
    }

    private func handleCommandTimeoutIsolated() {
        guard activeCommand != nil else { return }

        yieldToActiveCommand("[ERROR] Command timed out after \(commandTimeoutSeconds) seconds.")
        lastCompletedExitStatus = 124 // Match coreutils timeout exit code.

        // Escalate: interrupt → terminate → SIGKILL.
        if let stdinHandle {
            try? stdinHandle.write(contentsOf: Data([0x03])) // Ctrl-C
        }

        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            Task.detached {
                try? await Task.sleep(for: .seconds(2))
                kill(pid, SIGKILL)
            }
        }

        finishActiveCommand()
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

// MARK: - UTF-8 Pipe Decoder

/// Buffers incomplete UTF-8 sequences across pipe read boundaries.
/// Pipe `availableData` can split multi-byte characters (emoji, CJK, accented chars)
/// at arbitrary byte offsets. Without buffering, `String(decoding:as:)` replaces
/// the incomplete tail with U+FFFD and the next delivery's leading bytes are also
/// garbled. This decoder holds incomplete trailing bytes until the next delivery
/// completes the sequence.
final class UTF8PipeDecoder {

    private var pending = Data()

    /// Append raw bytes. Returns decoded text if any complete UTF-8 content is
    /// available, or nil if the entire chunk is an incomplete trailing sequence.
    func append(_ data: Data) -> String? {
        pending.append(data)

        // Try decoding the full buffer. If it succeeds, all bytes are valid UTF-8.
        if let result = String(data: pending, encoding: .utf8) {
            pending.removeAll(keepingCapacity: true)
            return result.isEmpty ? nil : result
        }

        // Decoding failed — likely an incomplete multi-byte sequence at the tail.
        // Walk backwards (up to 3 bytes — max continuation length in UTF-8) to find
        // the split point: everything before it is valid, everything after is pending.
        let maxTrail = min(pending.count, 3)
        for trim in 1...maxTrail {
            let candidate = pending.prefix(pending.count - trim)
            if let result = String(data: candidate, encoding: .utf8) {
                pending = Data(pending.suffix(trim))
                return result.isEmpty ? nil : result
            }
        }

        // Entire buffer is undecodable (shouldn't happen with valid UTF-8 streams).
        // Drain as lossy to avoid unbounded growth.
        let lossy = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return lossy.isEmpty ? nil : lossy
    }

    /// Flush any remaining buffered bytes (e.g., on stream close).
    func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let result = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return result.isEmpty ? nil : result
    }
}
