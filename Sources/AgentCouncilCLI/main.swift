// main.swift
// Studio.92 — Agent Builder CLI
// Swift executable: `swift run council "<goal>"`
//
// Usage:
//   export ANTHROPIC_API_KEY="sk-ant-..."
//   swift run council "Build the first iOS app shell for a live scoreboard"
//   swift run council --model opus "Fix the iOS build and prepare TestFlight upload"

import Foundation
import AgentCouncil

// MARK: - CLI Entry Point

@main
struct CouncilCLI {

    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        var dryRun = false
        var selectedModel = ClaudeModel.sonnet
        var maxIterations = 25
        var goalParts: [String] = []

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--dry-run":
                dryRun = true
            case "--model":
                if let raw = iterator.next() {
                    selectedModel = parseModel(from: raw)
                }
            case "--max-iterations":
                if let raw = iterator.next(), let value = Int(raw), value > 0 {
                    maxIterations = value
                }
            case "--help", "-h":
                printHelp()
                return
            default:
                goalParts.append(arg)
            }
        }

        let goal = goalParts.joined(separator: " ")

        guard !goal.isEmpty else {
            printHelp()
            exit(1)
        }

        if dryRun {
            runDryRun(goal: goal, model: selectedModel, maxIterations: maxIterations)
        } else {
            await runLive(goal: goal, model: selectedModel, maxIterations: maxIterations)
        }
    }

    // MARK: - Dry Run

    static func runDryRun(goal: String, model: ClaudeModel, maxIterations: Int) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let system = BuilderSystemPrompt.make(
            projectRoot: root
        )

        print("=== DRY RUN MODE ===")
        print("Goal: \(goal)")
        print("Model: \(model.rawValue)")
        print("Max iterations: \(maxIterations)")
        print()
        print("=== SYSTEM PROMPT ===")
        print(system)
        print()
        print("=== AVAILABLE TOOLS ===")
        AgentTools.all.forEach { tool in
            print("- \(tool.name)")
        }
    }

    // MARK: - Live Run

    static func runLive(
        goal: String,
        model: ClaudeModel,
        maxIterations: Int
    ) async {
        let api: ClaudeAPIClient
        do {
            api = try ClaudeAPIClient()
        } catch {
            printError("API key error: \(error)")
            exit(1)
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let toolExecutor = ToolExecutor(projectRoot: root)
        let orchestrator = AgenticOrchestrator(
            client: api,
            toolExecutor: toolExecutor,
            config: AgenticConfig(
                model: model,
                maxIterations: maxIterations
            )
        )
        let system = BuilderSystemPrompt.make(
            projectRoot: root
        )

        writeStdErr("Studio.92 Builder\n")
        writeStdErr("Goal: \(goal)\n")
        writeStdErr("Model: \(model.rawValue)\n\n")

        let events = await orchestrator.run(system: system, messages: [.user(goal)])
        var exitCode: Int32 = 0

        for await event in events {
            switch event {
            case .textDelta(let text):
                writeStdOut(text)
            case .thinkingDelta:
                break
            case .toolCallStart(_, let name):
                writeStdErr("\n[tool] \(name)\n")
            case .toolCallInputDelta:
                break
            case .toolCallResult(_, let output, let isError):
                let label = isError ? "tool error" : "tool result"
                writeStdErr("[\(label)] \(output)\n")
            case .usage(let inputTokens, let outputTokens):
                writeStdErr("[usage] in=\(inputTokens) out=\(outputTokens)\n")
            case .completed(let stopReason):
                writeStdErr("\n[completed] \(stopReason)\n")
            case .error(let message):
                writeStdErr("\n[error] \(message)\n")
                exitCode = 1
            }
        }

        if exitCode == 0 {
            writeStdOut("\n")
        }
        exit(exitCode)
    }

    // MARK: - Helpers

    private static func parseModel(from string: String) -> ClaudeModel {
        switch string.lowercased() {
        case "opus":   return .opus
        case "haiku":  return .haiku
        default:       return .sonnet
        }
    }

    private static func printHelp() {
        print("""
        Studio.92 Builder CLI

        USAGE:
          swift run council [options] "<goal>"

        OPTIONS:
          --dry-run               Print the active system prompt and available tools
          --model <model>         Model to use (opus|sonnet|haiku, default: sonnet)
          --max-iterations <n>    Max tool-use loops before stopping (default: 25)
          --help, -h              Show this help

        ENVIRONMENT:
          ANTHROPIC_API_KEY       Required
          OPENAI_API_KEY          Recommended for web research and advanced terminal execution

        EXAMPLES:
          export ANTHROPIC_API_KEY="sk-ant-..."
          swift run council "Build the first iOS app shell for a live scoreboard"
          swift run council --full-send --model opus "Fix the build, run tests, and prepare TestFlight upload"
        """)
    }

    private static func printError(_ message: String) {
        fputs("ERROR: \(message)\n", stderr)
    }

    private static func writeStdOut(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func writeStdErr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
