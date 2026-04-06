// ToolParallelism.swift
// AgentCouncil — Tool Execution Parallelism
//
// Classifies tools by safety for concurrent execution and partitions
// batches into parallel-safe and sequential groups. Reads targeting
// the same file as a pending write are demoted to sequential.

import Foundation

public enum ToolParallelism {

    // MARK: - Classification

    /// Returns `true` if the tool is read-only / side-effect-free and safe to
    /// execute concurrently with other parallelizable tools.
    public static func isParallelizable(_ toolName: String) -> Bool {
        guard let tool = ToolName(normalizing: toolName) else { return false }
        return ToolName.parallelizable.contains(tool)
    }

    // MARK: - Path Extraction

    /// Extracts the target file path from a tool call's raw JSON input.
    /// Returns `nil` for tools that don't operate on a specific file path.
    public static func targetPath(toolName: String, inputJSON: String) -> String? {
        guard let tool = ToolName(normalizing: toolName),
              ToolName.filePathTools.contains(tool) else {
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
    /// - Read-only tools (`file_read`, `list_files`, `web_search`) go to `parallel`.
    /// - Writes and side-effecting tools go to `sequential`.
    /// - A read that targets the same path as a pending write is demoted to `sequential`
    ///   to avoid stale reads.
    ///
    /// Each element in the returned arrays is `(originalIndex, call)` so results
    /// can be reassembled in the original order after execution.
    public static func partition<T>(
        _ calls: [T],
        name: (T) -> String,
        inputJSON: (T) -> String
    ) -> (parallel: [(Int, T)], sequential: [(Int, T)]) {
        // First pass: collect paths targeted by sequential (write) tools.
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
                // Demote if this read targets the same path as a pending write.
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
