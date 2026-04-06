// ToolError.swift
// Studio.92 — Agent Council
// Structured error taxonomy for tool execution failures.
// Replaces opaque string errors with machine-readable signals
// so the orchestrator can decide recovery strategy.

import Foundation

/// Classifies tool execution failures into actionable categories.
public enum ToolError: Error, Sendable {
    /// The tool attempted to access a path outside the sandbox.
    case sandboxViolation(tool: String, path: String)
    /// The tool is not permitted.
    case permissionBlocked(tool: String, reason: String)
    /// The tool execution exceeded its time limit.
    case timeout(tool: String, elapsed: TimeInterval)
    /// A shell command exited with a non-zero status.
    case executionFailed(tool: String, stderr: String, exitCode: Int32)
    /// The model provided invalid or missing input for the tool.
    case invalidInput(tool: String, reason: String)
    /// A subagent handoff consumed all available iterations.
    case iterationLimitReached(partialResult: HandoffResult)

    /// Human-readable description suitable for returning to the model.
    public var displayMessage: String {
        switch self {
        case .sandboxViolation(let tool, let path):
            return "[\(tool)] Sandbox violation: access denied for path \(path)"
        case .permissionBlocked(let tool, let reason):
            return "[\(tool)] Permission blocked: \(reason)"
        case .timeout(let tool, let elapsed):
            return "[\(tool)] Timed out after \(Int(elapsed))s"
        case .executionFailed(let tool, let stderr, let exitCode):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "" : "\n\(trimmed)"
            return "[\(tool)] Failed with exit code \(exitCode)\(detail)"
        case .invalidInput(let tool, let reason):
            return "[\(tool)] Invalid input: \(reason)"
        case .iterationLimitReached(let result):
            return "Subagent hit iteration limit (\(result.iterationCount) iterations). Partial: \(result.summary)"
        }
    }

    /// The tool name associated with this error, if any.
    public var toolName: String? {
        switch self {
        case .sandboxViolation(let t, _),
             .permissionBlocked(let t, _),
             .timeout(let t, _),
             .executionFailed(let t, _, _),
             .invalidInput(let t, _):
            return t
        case .iterationLimitReached:
            return nil
        }
    }
}

// MARK: - Recovery Strategy

/// The orchestrator's response plan for a given ToolError.
public enum RecoveryStrategy: Sendable, Equatable {
    /// Report the error to the model immediately. Do not retry.
    case failFast
    /// Retry the same operation with exponential backoff.
    case retryWithBackoff(maxAttempts: Int)
    /// Return the error with a structured hint so the model can self-correct.
    case retryAlternate(suggestion: String)
    /// Surface to the user — the model cannot resolve this alone.
    case escalateToUser(reason: String)
}

// MARK: - Policy Resolver

/// Pure function: maps a ToolError to the appropriate RecoveryStrategy.
/// Trivially testable, no configuration drift.
public func recoveryStrategy(for error: ToolError) -> RecoveryStrategy {
    switch error {
    case .sandboxViolation:
        return .failFast
    case .permissionBlocked:
        return .escalateToUser(reason: "mode_restriction")
    case .invalidInput:
        return .failFast
    case .timeout:
        return .retryWithBackoff(maxAttempts: 2)
    case .executionFailed(_, _, let code):
        // 137 = SIGKILL (typically OOM). Retry once — the environment may stabilize.
        if code == 137 {
            return .retryWithBackoff(maxAttempts: 1)
        }
        // General build/command failure: the model should interpret stderr and fix.
        return .retryAlternate(suggestion: "fix_and_retry")
    case .iterationLimitReached:
        return .escalateToUser(reason: "iteration_limit")
    }
}

// MARK: - Circuit Breaker

/// Three-state circuit breaker: closed (healthy) → open (tripped) → half-open (probing).
/// Prevents cascading retries when a downstream dependency is persistently failing.
/// Owned by RecoveryExecutor — shares its actor isolation, so no independent actor needed.
public struct CircuitBreaker: Sendable {

    public enum State: String, Sendable {
        case closed    // healthy — requests flow normally
        case open      // tripped — fail-fast until cooldown expires
        case halfOpen  // probing — allow one request through to test recovery
    }

    public struct Configuration: Sendable {
        public let failureThreshold: Int
        public let windowSeconds: TimeInterval
        public let cooldownSeconds: TimeInterval

        public init(failureThreshold: Int = 5, windowSeconds: TimeInterval = 30, cooldownSeconds: TimeInterval = 60) {
            self.failureThreshold = failureThreshold
            self.windowSeconds = windowSeconds
            self.cooldownSeconds = cooldownSeconds
        }
    }

    public let configuration: Configuration
    public private(set) var state: State = .closed
    private var failureTimestamps: [Date] = []
    private var lastOpenedAt: Date?
    private var consecutiveSuccesses: Int = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Check whether a request should be allowed through.
    public func shouldAllow() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            guard let openedAt = lastOpenedAt else { return false }
            if Date().timeIntervalSince(openedAt) >= configuration.cooldownSeconds {
                return true // will transition to half-open on next recordResult
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Record the outcome of a request. Drives state transitions.
    public mutating func recordSuccess() {
        switch state {
        case .closed:
            break
        case .open:
            // Shouldn't happen directly, but if cooldown expired and a success comes in, close.
            state = .closed
            failureTimestamps.removeAll()
            consecutiveSuccesses = 0
        case .halfOpen:
            state = .closed
            failureTimestamps.removeAll()
            consecutiveSuccesses = 0
        }
    }

    /// Record a failure. May trip the breaker if threshold is reached within the window.
    public mutating func recordFailure() {
        let now = Date()
        switch state {
        case .closed:
            failureTimestamps.append(now)
            evictExpired(now: now)
            if failureTimestamps.count >= configuration.failureThreshold {
                state = .open
                lastOpenedAt = now
            }
        case .open:
            // Already open — just refresh the timestamp window.
            lastOpenedAt = now
        case .halfOpen:
            // Probe failed — reopen.
            state = .open
            lastOpenedAt = now
        }
    }

    /// Transition from open to half-open if cooldown has elapsed.
    public mutating func tickIfNeeded() {
        guard state == .open, let openedAt = lastOpenedAt else { return }
        if Date().timeIntervalSince(openedAt) >= configuration.cooldownSeconds {
            state = .halfOpen
            consecutiveSuccesses = 0
        }
    }

    /// Reset the breaker to closed state (e.g. new run starting).
    public mutating func reset() {
        state = .closed
        failureTimestamps.removeAll()
        lastOpenedAt = nil
        consecutiveSuccesses = 0
    }

    private mutating func evictExpired(now: Date) {
        let cutoff = now.addingTimeInterval(-configuration.windowSeconds)
        failureTimestamps.removeAll { $0 < cutoff }
    }
}

// MARK: - Recovery Executor

/// Applies a RecoveryStrategy to a failed tool invocation, handling retries
/// with exponential backoff, cancellation awareness, and circuit breaker protection.
public actor RecoveryExecutor {

    private var tracer: TraceCollector?
    private var circuitBreaker: CircuitBreaker

    public init(
        tracer: TraceCollector? = nil,
        circuitBreakerConfig: CircuitBreaker.Configuration = CircuitBreaker.Configuration()
    ) {
        self.tracer = tracer
        self.circuitBreaker = CircuitBreaker(configuration: circuitBreakerConfig)
    }

    /// Inject or replace the trace collector (e.g. per-run tracer created after init).
    public func setTracer(_ tracer: TraceCollector?) {
        self.tracer = tracer
    }

    /// Reset the circuit breaker (e.g. at the start of a new run).
    public func resetCircuitBreaker() {
        circuitBreaker.reset()
    }

    /// Current circuit breaker state, for observability.
    public func circuitBreakerState() -> CircuitBreaker.State {
        circuitBreaker.state
    }

    /// Attempt recovery for a tool error. Returns the enriched error message
    /// to send back to the model (with retry context if applicable).
    /// The `retryBlock` re-executes the tool and returns `(result, isError)`.
    /// If the retry succeeds, returns `nil` (caller should use the retry result).
    public func attemptRecovery(
        for error: ToolError,
        retryBlock: @Sendable () async throws -> (String, Bool)?
    ) async -> RecoveryResult {
        let strategy = recoveryStrategy(for: error)

        // Circuit breaker gate — if open, skip retries entirely and fail fast.
        circuitBreaker.tickIfNeeded()
        if case .retryWithBackoff = strategy, !circuitBreaker.shouldAllow() {
            let spanID = await tracer?.begin(
                kind: .retry,
                name: "circuit_breaker_reject",
                attributes: [
                    "breaker_state": circuitBreaker.state.rawValue,
                    "error": error.displayMessage
                ]
            )
            if let spanID { await tracer?.end(spanID, error: "Circuit breaker open") }
            return .error("\(error.displayMessage)\n[Circuit breaker open — retries suppressed]")
        }

        switch strategy {
        case .failFast:
            circuitBreaker.recordFailure()
            return .error(error.displayMessage)

        case .retryWithBackoff(let maxAttempts):
            return await executeRetries(
                error: error,
                maxAttempts: maxAttempts,
                retryBlock: retryBlock
            )

        case .retryAlternate(let suggestion):
            let hint: String
            switch suggestion {
            case "fix_and_retry":
                hint = "Read the error output, apply a fix to the source, then retry."
            default:
                hint = suggestion
            }
            return .error("\(error.displayMessage)\n\n[Recovery hint: \(hint)]")

        case .escalateToUser(let reason):
            let spanID = await tracer?.begin(
                kind: .retry,
                name: "escalation",
                attributes: ["reason": reason, "error": error.displayMessage]
            )
            if let spanID {
                await tracer?.end(spanID, error: "Escalated to user: \(reason)")
            }
            return .escalated(error.displayMessage, reason: reason)
        }
    }

    // MARK: - Retry Loop

    private func executeRetries(
        error: ToolError,
        maxAttempts: Int,
        retryBlock: @Sendable () async throws -> (String, Bool)?
    ) async -> RecoveryResult {
        var lastError = error.displayMessage
        let toolName = error.toolName ?? "unknown"

        for attempt in 1...maxAttempts {
            // Respect cancellation — no zombie retries after the user hits Stop.
            guard !Task.isCancelled else {
                return .error("\(lastError)\n[Retry cancelled]")
            }

            // Check circuit breaker before each attempt.
            circuitBreaker.tickIfNeeded()
            if !circuitBreaker.shouldAllow() {
                return .error("\(lastError)\n[Circuit breaker opened during retry — remaining attempts suppressed]")
            }

            let backoffNanos = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
            let cappedNanos = min(backoffNanos, 12_000_000_000) // cap at 12s
            // Jitter: randomize ±25% to prevent thundering herd
            let jitteredNanos = UInt64(Double(cappedNanos) * Double.random(in: 0.75...1.25))

            let spanID = await tracer?.begin(
                kind: .retry,
                name: "retry_attempt",
                attributes: [
                    "tool": toolName,
                    "attempt": "\(attempt)/\(maxAttempts)",
                    "backoff_ms": "\(jitteredNanos / 1_000_000)",
                    "breaker_state": circuitBreaker.state.rawValue
                ]
            )

            do {
                try await Task.sleep(nanoseconds: jitteredNanos)
            } catch {
                // Task was cancelled during sleep.
                if let spanID { await tracer?.end(spanID, error: "cancelled") }
                return .error("\(lastError)\n[Retry cancelled]")
            }

            do {
                if let (result, isError) = try await retryBlock() {
                    if !isError {
                        if let spanID { await tracer?.end(spanID) }
                        circuitBreaker.recordSuccess()
                        return .retrySucceeded(result, attempts: attempt)
                    }
                    lastError = result
                }
            } catch {
                lastError = error.localizedDescription
            }

            circuitBreaker.recordFailure()
            if let spanID { await tracer?.end(spanID, error: lastError) }
        }

        return .error("\(lastError)\n[Failed after \(maxAttempts) retry attempt(s)]")
    }
}

// MARK: - Recovery Result

/// Outcome of a recovery attempt.
public enum RecoveryResult: Sendable {
    /// Tool error, enriched with retry/hint context. Return to model as is_error=true.
    case error(String)
    /// Retry succeeded — use the provided result instead.
    case retrySucceeded(String, attempts: Int)
    /// Requires human intervention. The orchestrator should pause or surface UI.
    case escalated(String, reason: String)

    /// Whether the recovery resulted in a usable success.
    public var succeeded: Bool {
        if case .retrySucceeded = self { return true }
        return false
    }

    /// The text payload to return to the model.
    public var displayText: String {
        switch self {
        case .error(let msg): return msg
        case .retrySucceeded(let msg, let n): return "\(msg)\n[Succeeded on retry attempt \(n)]"
        case .escalated(let msg, _): return msg
        }
    }

    /// Whether this should be marked as an error in the tool result.
    public var isError: Bool {
        switch self {
        case .error, .escalated: return true
        case .retrySucceeded: return false
        }
    }
}
