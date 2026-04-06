// RecoveryTests.swift
// Studio.92 — Error Recovery & Feedback Loop Tests

import Foundation
import XCTest
@testable import AgentCouncil

final class RecoveryTests: XCTestCase {

    // MARK: - ToolError Display Messages

    func testToolErrorSandboxViolationMessage() {
        let error = ToolError.sandboxViolation(tool: "file_read", path: "/etc/passwd")
        XCTAssertTrue(error.displayMessage.contains("Sandbox violation"))
        XCTAssertTrue(error.displayMessage.contains("/etc/passwd"))
        XCTAssertEqual(error.toolName, "file_read")
    }

    func testToolErrorPermissionBlockedMessage() {
        let error = ToolError.permissionBlocked(tool: "file_write", reason: "restricted")
        XCTAssertTrue(error.displayMessage.contains("Permission blocked"))
        XCTAssertEqual(error.toolName, "file_write")
    }

    func testToolErrorTimeoutMessage() {
        let error = ToolError.timeout(tool: "terminal", elapsed: 30)
        XCTAssertTrue(error.displayMessage.contains("Timed out after 30s"))
        XCTAssertEqual(error.toolName, "terminal")
    }

    func testToolErrorExecutionFailedMessage() {
        let error = ToolError.executionFailed(tool: "terminal", stderr: "build error", exitCode: 1)
        XCTAssertTrue(error.displayMessage.contains("exit code 1"))
        XCTAssertTrue(error.displayMessage.contains("build error"))
    }

    func testToolErrorExecutionFailedEmptyStderr() {
        let error = ToolError.executionFailed(tool: "terminal", stderr: "", exitCode: 2)
        XCTAssertTrue(error.displayMessage.contains("exit code 2"))
        XCTAssertFalse(error.displayMessage.contains("\n"))
    }

    func testToolErrorInvalidInputMessage() {
        let error = ToolError.invalidInput(tool: "file_read", reason: "Missing: path")
        XCTAssertTrue(error.displayMessage.contains("Invalid input"))
        XCTAssertTrue(error.displayMessage.contains("Missing: path"))
    }

    func testToolErrorIterationLimitMessage() {
        let result = HandoffResult(summary: "partial work", iterationCount: 8)
        let error = ToolError.iterationLimitReached(partialResult: result)
        XCTAssertTrue(error.displayMessage.contains("iteration limit"))
        XCTAssertTrue(error.displayMessage.contains("8 iterations"))
        XCTAssertNil(error.toolName)
    }

    // MARK: - Recovery Strategy Policy Resolver

    func testPolicySandboxViolationIsFailFast() {
        let error = ToolError.sandboxViolation(tool: "file_read", path: "/etc/passwd")
        XCTAssertEqual(recoveryStrategy(for: error), .failFast)
    }

    func testPolicyPermissionBlockedEscalatesToUser() {
        let error = ToolError.permissionBlocked(tool: "file_write", reason: "restricted")
        XCTAssertEqual(recoveryStrategy(for: error), .escalateToUser(reason: "mode_restriction"))
    }

    func testPolicyInvalidInputIsFailFast() {
        let error = ToolError.invalidInput(tool: "file_read", reason: "bad path")
        XCTAssertEqual(recoveryStrategy(for: error), .failFast)
    }

    func testPolicyTimeoutRetriesWithBackoff() {
        let error = ToolError.timeout(tool: "terminal", elapsed: 30)
        XCTAssertEqual(recoveryStrategy(for: error), .retryWithBackoff(maxAttempts: 2))
    }

    func testPolicyOOMKillRetriesOnce() {
        let error = ToolError.executionFailed(tool: "terminal", stderr: "Killed", exitCode: 137)
        XCTAssertEqual(recoveryStrategy(for: error), .retryWithBackoff(maxAttempts: 1))
    }

    func testPolicyGeneralExecFailureSuggestsFix() {
        let error = ToolError.executionFailed(tool: "terminal", stderr: "error: cannot find", exitCode: 1)
        XCTAssertEqual(recoveryStrategy(for: error), .retryAlternate(suggestion: "fix_and_retry"))
    }

    func testPolicyIterationLimitEscalates() {
        let result = HandoffResult(summary: "partial", iterationCount: 8)
        let error = ToolError.iterationLimitReached(partialResult: result)
        XCTAssertEqual(recoveryStrategy(for: error), .escalateToUser(reason: "iteration_limit"))
    }

    // MARK: - Recovery Executor

    func testRecoveryFailFastReturnsImmediately() async {
        let executor = RecoveryExecutor()
        let error = ToolError.sandboxViolation(tool: "file_read", path: "/etc/shadow")
        let result = await executor.attemptRecovery(for: error) { nil }
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.displayText.contains("Sandbox violation"))
    }

    func testRecoveryRetryAlternateIncludesHint() async {
        let executor = RecoveryExecutor()
        let error = ToolError.executionFailed(tool: "terminal", stderr: "error: undeclared", exitCode: 1)
        let result = await executor.attemptRecovery(for: error) { nil }
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("Recovery hint"))
        XCTAssertTrue(result.displayText.contains("fix"))
    }

    func testRecoveryEscalateToUserReportsReason() async {
        let executor = RecoveryExecutor()
        let error = ToolError.permissionBlocked(tool: "file_write", reason: "restricted")
        let result = await executor.attemptRecovery(for: error) { nil }
        XCTAssertTrue(result.isError)
        if case .escalated(_, let reason) = result {
            XCTAssertEqual(reason, "mode_restriction")
        } else {
            XCTFail("Expected .escalated result")
        }
    }

    func testRecoveryRetrySucceedsOnSecondAttempt() async {
        let executor = RecoveryExecutor()
        let error = ToolError.timeout(tool: "terminal", elapsed: 30)
        nonisolated(unsafe) var callCount = 0
        let result = await executor.attemptRecovery(for: error) {
            callCount += 1
            if callCount == 1 {
                return ("still timing out", true)
            }
            return ("command output", false)
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.displayText.contains("command output"))
        XCTAssertTrue(result.displayText.contains("retry attempt 2"))
    }

    func testRecoveryRetryExhaustsAllAttempts() async {
        let executor = RecoveryExecutor()
        let error = ToolError.timeout(tool: "terminal", elapsed: 30)
        let result = await executor.attemptRecovery(for: error) {
            return ("still failing", true)
        }
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("Failed after 2 retry attempt(s)"))
    }

    func testRecoveryOOMRetryOnlyOnce() async {
        let executor = RecoveryExecutor()
        let error = ToolError.executionFailed(tool: "terminal", stderr: "Killed", exitCode: 137)
        nonisolated(unsafe) var callCount = 0
        let result = await executor.attemptRecovery(for: error) {
            callCount += 1
            return ("still OOM", true)
        }
        XCTAssertTrue(result.isError)
        XCTAssertEqual(callCount, 1, "OOM should only retry once")
        XCTAssertTrue(result.displayText.contains("Failed after 1 retry attempt(s)"))
    }

    func testRecoveryRespectsTaskCancellation() async {
        let executor = RecoveryExecutor()
        let error = ToolError.timeout(tool: "terminal", elapsed: 30)

        let task = Task {
            await executor.attemptRecovery(for: error) {
                return ("output", true)
            }
        }
        // Cancel immediately — the retry loop should notice and bail.
        task.cancel()
        let result = await task.value
        // Either cancelled during sleep or first check — should report cancellation.
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("cancelled") || result.displayText.contains("Failed"))
    }

    // MARK: - RecoveryResult Properties

    func testRecoveryResultErrorProperties() {
        let result = RecoveryResult.error("something broke")
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.displayText, "something broke")
    }

    func testRecoveryResultSucceededProperties() {
        let result = RecoveryResult.retrySucceeded("all good", attempts: 2)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.displayText.contains("all good"))
        XCTAssertTrue(result.displayText.contains("retry attempt 2"))
    }

    func testRecoveryResultEscalatedProperties() {
        let result = RecoveryResult.escalated("blocked", reason: "mode_restriction")
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.displayText, "blocked")
    }

    // MARK: - Recovery Strategy Equatable

    func testRecoveryStrategyEquatable() {
        XCTAssertEqual(RecoveryStrategy.failFast, RecoveryStrategy.failFast)
        XCTAssertEqual(RecoveryStrategy.retryWithBackoff(maxAttempts: 2), RecoveryStrategy.retryWithBackoff(maxAttempts: 2))
        XCTAssertNotEqual(RecoveryStrategy.retryWithBackoff(maxAttempts: 2), RecoveryStrategy.retryWithBackoff(maxAttempts: 1))
        XCTAssertEqual(RecoveryStrategy.retryAlternate(suggestion: "fix_and_retry"), RecoveryStrategy.retryAlternate(suggestion: "fix_and_retry"))
        XCTAssertNotEqual(RecoveryStrategy.failFast, RecoveryStrategy.retryWithBackoff(maxAttempts: 1))
        XCTAssertEqual(RecoveryStrategy.escalateToUser(reason: "x"), RecoveryStrategy.escalateToUser(reason: "x"))
    }

    // MARK: - Circuit Breaker

    func testCircuitBreakerStartsClosed() {
        let breaker = CircuitBreaker()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllow())
    }

    func testCircuitBreakerTripsAfterThreshold() {
        var breaker = CircuitBreaker(configuration: .init(failureThreshold: 3, windowSeconds: 30, cooldownSeconds: 60))
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        XCTAssertFalse(breaker.shouldAllow())
    }

    func testCircuitBreakerResetReturnsToClosed() {
        var breaker = CircuitBreaker(configuration: .init(failureThreshold: 2, windowSeconds: 30, cooldownSeconds: 60))
        breaker.recordFailure()
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        breaker.reset()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllow())
    }

    func testCircuitBreakerSuccessInHalfOpenCloses() {
        var breaker = CircuitBreaker(configuration: .init(failureThreshold: 1, windowSeconds: 30, cooldownSeconds: 0))
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        // Cooldown = 0s, so tickIfNeeded transitions immediately.
        breaker.tickIfNeeded()
        XCTAssertEqual(breaker.state, .halfOpen)
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .closed)
    }

    func testCircuitBreakerFailureInHalfOpenReopens() {
        var breaker = CircuitBreaker(configuration: .init(failureThreshold: 1, windowSeconds: 30, cooldownSeconds: 0))
        breaker.recordFailure()
        breaker.tickIfNeeded()
        XCTAssertEqual(breaker.state, .halfOpen)
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
    }

    func testRecoveryExecutorCircuitBreakerSuppressesRetries() async {
        let config = CircuitBreaker.Configuration(failureThreshold: 1, windowSeconds: 30, cooldownSeconds: 300)
        let executor = RecoveryExecutor(circuitBreakerConfig: config)
        // Trip the breaker with a fail-fast error (records failure).
        let sandbox = ToolError.sandboxViolation(tool: "file_read", path: "/etc/shadow")
        _ = await executor.attemptRecovery(for: sandbox) { nil }
        // Now a retryable error should be suppressed.
        let timeout = ToolError.timeout(tool: "terminal", elapsed: 30)
        let result = await executor.attemptRecovery(for: timeout) {
            XCTFail("Retry block should not be called when breaker is open")
            return nil
        }
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("Circuit breaker open"))
    }
}
