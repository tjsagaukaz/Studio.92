// main.swift
// Studio.92 — Executor CLI
// GPT-4.5 powered build-repair tool.
//
// USAGE:
//   swift run executor --errors compiler_errors.txt [--project-root <path>] [--max-retries 3] [--verbose]
//   cat compiler_errors.txt | swift run executor --project-root /path/to/repo

import Foundation
import Executor

@main
struct ExecutorCLIMain {

    static func main() async {
        var errorsPath:  String? = nil
        var projectRoot: String  = FileManager.default.currentDirectoryPath
        var maxRetries:  Int     = 3
        var verbose:     Bool    = false
        var model:       String  = OpenAIModel.gpt45.rawValue

        // Parse arguments
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--errors":
                errorsPath = args.next()
            case "--project-root":
                projectRoot = args.next() ?? projectRoot
            case "--max-retries":
                if let val = args.next(), let n = Int(val) {
                    maxRetries = n
                }
            case "--model":
                model = args.next() ?? model
            case "--verbose":
                verbose = true
            case "--help", "-h":
                printUsage()
                return
            default:
                break
            }
        }

        // Create API client
        let api: OpenAIAPIClient
        do {
            // Check for explicit key in environment or app settings
            if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
                api = OpenAIAPIClient(apiKey: key)
            } else {
                api = try OpenAIAPIClient()
            }
        } catch {
            stderr("Error: \(error)")
            stderr("Set OPENAI_API_KEY environment variable.")
            exit(1)
        }

        let config = ExecutorConfig(
            maxRetries:         maxRetries,
            projectRoot:        projectRoot,
            compilerErrorsPath: errorsPath,
            model:              model,
            verbose:            verbose
        )

        let agent = ExecutorAgent(api: api, config: config)

        stderr("[executor] Starting build repair...")
        stderr("[executor] Project root: \(projectRoot)")
        if let path = errorsPath {
            stderr("[executor] Errors file: \(path)")
        } else {
            stderr("[executor] Reading errors from stdin")
        }

        do {
            let result = try await agent.run()

            // Output result as JSON to stdout
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            print(jsonString)

            switch result.status {
            case .fixed:
                stderr("[executor] Build fixed after \(result.attemptsUsed) attempt(s)")
                stderr("[executor] Files modified: \(result.filesModified.joined(separator: ", "))")
                exit(0)
            case .noErrors:
                stderr("[executor] No errors to fix")
                exit(0)
            case .failed:
                stderr("[executor] Failed after \(result.attemptsUsed) attempt(s)")
                exit(1)
            }
        } catch {
            stderr("[executor] Fatal error: \(error)")
            exit(1)
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private static func printUsage() {
        let usage = """
        USAGE:
          swift run executor --errors <path> [OPTIONS]
          cat errors.txt | swift run executor --project-root <path>

        OPTIONS:
          --errors <path>        Path to compiler errors file (or pipe via stdin)
          --project-root <path>  Project root directory (default: current directory)
          --max-retries <n>      Maximum fix attempts (default: 3)
          --model <model>        OpenAI model ID (default: gpt-4.5-preview)
          --verbose              Print progress to stderr
          --help                 Show this help

        ENVIRONMENT:
          OPENAI_API_KEY         Required. OpenAI API key.
          STUDIO92_WORKSPACE     Xcode workspace path (for xcodebuild)
          STUDIO92_SCHEME        Xcode scheme name (for xcodebuild)

        EXAMPLES:
          swift run executor --errors build_errors.txt --project-root ~/MyApp --verbose
          xcodebuild build 2>&1 | swift run executor --project-root ~/MyApp
        """
        print(usage)
    }
}
