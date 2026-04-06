// ToolParallelism.swift
// Studio.92 — Command Center
//
// Classifies tools by safety for concurrent execution and partitions
// batches into parallel-safe and sequential groups. Reads targeting
// the same file as a pending write are demoted to sequential.

import Foundation

// MARK: - Canonical Tool Names

/// All tool names recognised by the CommandCenter agentic loop.
/// Using this enum instead of raw strings provides compile-time safety
/// and exhaustive switch coverage across dispatch, parallelism, and UI.
enum StudioToolName: String, Sendable, CaseIterable, Hashable {
    case fileRead              = "file_read"
    case fileWrite             = "file_write"
    case filePatch             = "file_patch"
    case listFiles             = "list_files"
    case delegateToExplorer    = "delegate_to_explorer"
    case delegateToReviewer    = "delegate_to_reviewer"
    case delegateToWorktree    = "delegate_to_worktree"
    case terminal              = "terminal"
    case webSearch             = "web_search"
    case webFetch              = "web_fetch"
    case deployToTestFlight    = "deploy_to_testflight"
    case screenshotSimulator   = "screenshot_simulator"
    case xcodeBuild            = "xcode_build"
    case xcodePreview          = "xcode_preview"

    /// Resolve aliases produced by different LLM providers into canonical names.
    init?(normalizing raw: String) {
        if let exact = StudioToolName(rawValue: raw) {
            self = exact
            return
        }
        switch raw {
        case "read_file":                               self = .fileRead
        case "create_file", "write_file":               self = .fileWrite
        case "apply_patch":                             self = .filePatch
        case "list_dir", "file_search",
             "grep_search", "semantic_search":          self = .listFiles
        case "fetch_webpage":                           self = .webFetch
        case "run_in_terminal":                         self = .terminal
        default:                                        return nil
        }
    }

    /// Read-only, side-effect-free tools safe for concurrent execution.
    static let parallelizable: Set<StudioToolName> = [.fileRead, .listFiles, .webSearch, .webFetch]

    /// Tools that operate on a file path (extractable from input JSON).
    static let filePathTools: Set<StudioToolName> = [.fileRead, .fileWrite, .filePatch]
}

// MARK: - Parallelism Partitioning

enum ToolParallelism {

    // MARK: - Classification

    /// Returns `true` if the tool is read-only / side-effect-free and safe to
    /// execute concurrently with other parallelizable tools.
    static func isParallelizable(_ toolName: String) -> Bool {
        guard let tool = StudioToolName(normalizing: toolName) else { return false }
        return StudioToolName.parallelizable.contains(tool)
    }

    // MARK: - Path Extraction

    /// Extracts the target file path from a tool call's raw JSON input.
    /// Returns `nil` for tools that don't operate on a specific file path.
    static func targetPath(toolName: String, inputJSON: String) -> String? {
        guard let tool = StudioToolName(normalizing: toolName),
              StudioToolName.filePathTools.contains(tool) else {
            return nil
        }
        guard let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["path"] as? String ?? obj["file_path"] as? String
    }

    // MARK: - Partition

    /// Partitions tool calls into parallel-safe and sequential groups.
    ///
    /// Each element in the returned arrays is `(originalIndex, call)` so results
    /// can be reassembled in the original order after execution.
    static func partition<T>(
        _ calls: [T],
        name: (T) -> String,
        inputJSON: (T) -> String
    ) -> (parallel: [(Int, T)], sequential: [(Int, T)]) {
        var writePaths: Set<String> = []
        for call in calls {
            let toolName = name(call)
            if !isParallelizable(toolName),
               let path = targetPath(toolName: toolName, inputJSON: inputJSON(call)) {
                writePaths.insert(path)
            }
        }

        var parallel: [(Int, T)] = []
        var sequential: [(Int, T)] = []

        for (index, call) in calls.enumerated() {
            let toolName = name(call)
            if isParallelizable(toolName) {
                if let path = targetPath(toolName: toolName, inputJSON: inputJSON(call)),
                   writePaths.contains(path) {
                    sequential.append((index, call))
                } else {
                    parallel.append((index, call))
                }
            } else {
                sequential.append((index, call))
            }
        }

        return (parallel: parallel, sequential: sequential)
    }
}
