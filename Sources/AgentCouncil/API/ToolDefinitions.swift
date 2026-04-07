// ToolDefinitions.swift
// Studio.92 — Agent Council
// Anthropic tool_use schemas for the agentic orchestrator.
// Each tool maps to a handler in ToolExecutor.

import Foundation

/// Canonical tool names used by the agentic orchestrator. Using this enum
/// instead of raw strings provides compile-time safety and exhaustive
/// switch coverage across dispatch, parallelism, and UI layers.
public enum ToolName: String, Sendable, CaseIterable, Hashable {
    case fileRead            = "file_read"
    case fileWrite           = "file_write"
    case filePatch           = "file_patch"
    case listFiles           = "list_files"
    case grepSearch          = "grep_search"
    case semanticSearch      = "semantic_search"
    case findSymbol          = "find_symbol"
    case findUsages          = "find_usages"
    case delegateToExplorer  = "delegate_to_explorer"
    case delegateToReviewer  = "delegate_to_reviewer"
    case terminal            = "terminal"
    case webSearch           = "web_search"
    case deployToTestFlight  = "deploy_to_testflight"

    /// Resolve aliases produced by different LLM providers into canonical names.
    public init?(normalizing raw: String) {
        if let exact = ToolName(rawValue: raw) {
            self = exact
            return
        }
        switch raw {
        case "read_file":                               self = .fileRead
        case "create_file", "write_file":               self = .fileWrite
        case "apply_patch":                             self = .filePatch
        case "list_dir", "file_search":               self = .listFiles
        case "grep_search":                             self = .grepSearch
        case "semantic_search":                         self = .semanticSearch
        case "find_symbol":                            self = .findSymbol
        case "find_usages":                            self = .findUsages
        case "fetch_webpage":                           self = .webSearch
        case "run_in_terminal":                         self = .terminal
        default:                                        return nil
        }
    }

    /// Read-only, side-effect-free tools safe for concurrent execution.
    public static let parallelizable: Set<ToolName> = [.fileRead, .listFiles, .grepSearch, .semanticSearch, .findSymbol, .findUsages, .webSearch]

    /// Tools that operate on a file path (extractable from input JSON).
    public static let filePathTools: Set<ToolName> = [.fileRead, .fileWrite, .filePatch]
}

public enum AgentTools {

    /// All tools available to the agentic orchestrator.
    public static let all: [ToolDefinition] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
        grepSearch,
        semanticSearch,
        findSymbol,
        findUsages,
        delegateToExplorer,
        delegateToReviewer,
        terminal,
        webSearch,
        deployToTestFlight
    ]

    // MARK: - File Operations

    public static let fileRead = ToolDefinition(
        name: "file_read",
        description: "Read the contents of a UTF-8 text file at the given path and return the file contents. Use this when you need grounded source context before making a change or when you need to verify how an existing implementation works. Prefer targeted reads of the most relevant files instead of broad repository sweeps. This tool returns raw file text and should not be used for directories or binary assets.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path": PropertySchema(type: "string", description: "Absolute or project-relative file path to read.")
            ],
            required: ["path"]
        ),
        strict: true,
        inputExamples: [
            ["path": .string("Sources/AgentCouncil/AgentCouncil.swift")]
        ]
    )

    public static let fileWrite = ToolDefinition(
        name: "file_write",
        description: "Create a new file or fully overwrite an existing UTF-8 text file with the provided contents. Use this when creating a new source file or intentionally replacing the entire contents of a file after you already understand the target. Do not use this for tiny edits when file_patch would be safer and more precise. Intermediate directories are created automatically when needed.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path":    PropertySchema(type: "string", description: "Absolute or project-relative file path to write."),
                "content": PropertySchema(type: "string", description: "The full file content to write.")
            ],
            required: ["path", "content"]
        ),
        strict: true
    )

    public static let filePatch = ToolDefinition(
        name: "file_patch",
        description: "Apply a precise search-and-replace edit to an existing file. Use this for focused modifications when you know the exact old text that should be replaced, and prefer it over file_write for small or surgical edits. The old_string must match exactly one location in the file; if it matches zero or multiple locations, the patch will fail and you should provide more specific context. This tool is ideal for anchored edits that should not disturb unrelated surrounding code.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path":       PropertySchema(type: "string", description: "Absolute or project-relative file path to patch."),
                "old_string": PropertySchema(type: "string", description: "The exact text to find in the file. Must be unique."),
                "new_string": PropertySchema(type: "string", description: "The replacement text.")
            ],
            required: ["path", "old_string", "new_string"]
        ),
        strict: true,
        inputExamples: [
            [
                "path": .string("Sources/App/FeatureView.swift"),
                "old_string": .string("Text(\"Hello\")"),
                "new_string": .string("Text(\"Hello, world\")")
            ]
        ]
    )

    public static let listFiles = ToolDefinition(
        name: "list_files",
        description: "List the files and directories at the provided path, optionally walking recursively up to a shallow depth. Use this to orient yourself in a focused area of the project when you do not yet know the exact filename you need. Prefer listing a relevant subdirectory instead of scanning the whole repository. Directory names are returned with a trailing slash.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path":      PropertySchema(type: "string", description: "Directory path to list. Defaults to project root if omitted."),
                "recursive": PropertySchema(type: "boolean", description: "If true, list recursively up to 3 levels deep. Default false.")
            ],
            required: []
        ),
        strict: false
    )

    public static let grepSearch = ToolDefinition(
        name: "grep_search",
        description: "Run an exact workspace search against current on-disk files and return precise path, line, and column matches. Use this when you know a literal string or regex to search for and want deterministic, bounded results without reading whole files. This is safer than broad file reads because it returns only the matching lines and small local context.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "query": PropertySchema(type: "string", description: "Exact string or regex to search for."),
                "is_regexp": PropertySchema(type: "boolean", description: "Interpret query as a regular expression. Defaults to false."),
                "case_sensitive": PropertySchema(type: "boolean", description: "Use case-sensitive matching. Defaults to false."),
                "path": PropertySchema(type: "string", description: "Optional file or directory path to search within."),
                "paths": PropertySchema(
                    type: "array",
                    description: "Optional list of file or directory paths to search within.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative path.")
                ),
                "max_results": PropertySchema(type: "integer", description: "Maximum number of matches to return. Defaults to 50, max 500."),
                "context_lines": PropertySchema(type: "integer", description: "Number of context lines to include before and after each match. Defaults to 1, max 5.")
            ],
            required: ["query"]
        ),
        strict: false,
        inputExamples: [
            [
                "query": .string("ExecutionLoopEngine"),
                "path": .string("CommandCenter/Execution"),
                "max_results": .int(25)
            ]
        ]
    )

    public static let semanticSearch = ToolDefinition(
        name: "semantic_search",
        description: "Run a structured semantic retrieval pass over the incrementally indexed workspace using SQLite FTS over declaration-aware Swift chunks. Use this when the query is conceptual, architectural, or pattern-based and exact token matching would miss relevant code. Results are deterministic and include ranked chunks with path, line range, summary, and snippet.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "query": PropertySchema(type: "string", description: "Conceptual or architectural search query."),
                "path": PropertySchema(type: "string", description: "Optional file or directory path to constrain retrieval."),
                "paths": PropertySchema(
                    type: "array",
                    description: "Optional list of file or directory paths to constrain retrieval.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative path.")
                ),
                "max_results": PropertySchema(type: "integer", description: "Maximum number of ranked chunks to return. Defaults to 12, max 50.")
            ],
            required: ["query"]
        ),
        strict: false,
        inputExamples: [
            [
                "query": .string("streaming pipeline orchestration"),
                "path": .string("CommandCenter/Execution"),
                "max_results": .int(8)
            ]
        ]
    )

    public static let findSymbol = ToolDefinition(
        name: "find_symbol",
        description: "Resolve indexed workspace symbols by semantic identity using IndexStoreDB canonical occurrences, then validate returned definitions with SourceKit. Use this when you need a real symbol definition rather than a text match. Results are deterministic, include USR, file, line, and column, and are constrained to workspace-owned source files.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "query": PropertySchema(type: "string", description: "Symbol name or name fragment to resolve."),
                "path": PropertySchema(type: "string", description: "Optional file or directory path to constrain symbol resolution."),
                "paths": PropertySchema(
                    type: "array",
                    description: "Optional list of file or directory paths to constrain symbol resolution.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative path.")
                ),
                "max_results": PropertySchema(type: "integer", description: "Maximum number of symbols to return. Defaults to 12, max 50.")
            ],
            required: ["query"]
        ),
        strict: false,
        inputExamples: [
            [
                "query": .string("RepositoryMonitor"),
                "path": .string("CommandCenter/Workspace"),
                "max_results": .int(5)
            ]
        ]
    )

    public static let findUsages = ToolDefinition(
        name: "find_usages",
        description: "Find semantic symbol occurrences using IndexStoreDB USRs. Resolve the symbol either from an explicit USR or from an exact file, line, and column validated by SourceKit prepare-rename. Use this for real cross-file usages and call sites, not text-based references.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "usr": PropertySchema(type: "string", description: "Optional Unified Symbol Resolution string. If omitted, path + line + column are required."),
                "path": PropertySchema(type: "string", description: "File path containing the target symbol when resolving by location."),
                "line": PropertySchema(type: "integer", description: "1-based line containing the target symbol when resolving by location."),
                "column": PropertySchema(type: "integer", description: "1-based UTF-8 column containing the target symbol when resolving by location."),
                "paths": PropertySchema(
                    type: "array",
                    description: "Optional list of file or directory paths to constrain returned usages.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative path.")
                ),
                "include_definitions": PropertySchema(type: "boolean", description: "Include definitions and declarations in the returned occurrences. Defaults to true."),
                "max_results": PropertySchema(type: "integer", description: "Maximum number of occurrences to return. Defaults to 200, max 500.")
            ],
            required: []
        ),
        strict: false,
        inputExamples: [
            [
                "path": .string("CommandCenter/Workspace/RepositoryMonitor.swift"),
                "line": .int(5),
                "column": .int(13),
                "max_results": .int(50)
            ]
        ]
    )

    public static let delegateToExplorer = ToolDefinition(
        name: "delegate_to_explorer",
        description: "Spawn a focused background codebase explorer that stays read-only and gathers broad context before you write code. Use this when the task requires tracing data flow across multiple files, comparing implementations in several directories, or investigating a subsystem without polluting your main context window. Provide a concrete objective and the most relevant target directories so the explorer can stay narrow. The explorer returns only a concise, high-density findings summary, not raw file transcripts.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "objective": PropertySchema(type: "string", description: "What the explorer should learn or trace through the codebase."),
                "target_directories": PropertySchema(
                    type: "array",
                    description: "Relevant directories for the explorer to inspect first.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative directory path.")
                )
            ],
            required: ["objective", "target_directories"]
        ),
        strict: true,
        inputExamples: [
            [
                "objective": .string("Trace how session state flows from login to the main dashboard."),
                "target_directories": .array([
                    .string("Sources/App/Auth"),
                    .string("Sources/App/Session")
                ])
            ]
        ]
    )

    public static let delegateToReviewer = ToolDefinition(
        name: "delegate_to_reviewer",
        description: "Spawn a specialized read-only reviewer to audit specific files for correctness, performance, security, and strict Apple-platform quality issues. Use this after meaningful code changes, when you want a second pass on risky files, or when you need a terse audit focused on one area. Provide only the files that actually matter and a concrete focus area so the reviewer stays sharp. The reviewer returns a short structured findings list rather than long explanations or raw code dumps.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "files_to_review": PropertySchema(
                    type: "array",
                    description: "Files the reviewer should audit.",
                    items: SchemaItems(type: "string", description: "Absolute or project-relative file path.")
                ),
                "focus_area": PropertySchema(type: "string", description: "The audit lens, such as performance, security, architecture, or Apple HIG compliance.")
            ],
            required: ["files_to_review", "focus_area"]
        ),
        strict: true,
        inputExamples: [
            [
                "files_to_review": .array([
                    .string("Sources/App/ContentView.swift"),
                    .string("Sources/App/AppModel.swift")
                ]),
                "focus_area": .string("Concurrency safety and HIG compliance")
            ]
        ]
    )

    // MARK: - Terminal

    public static let terminal = ToolDefinition(
        name: "terminal",
        description: "Execute a shell command in the project directory and return merged stdout and stderr. Use this for builds, tests, verification, git inspection, and other workspace CLI tasks when shell output would reduce guesswork or validate a change. Prefer concise, purposeful commands that operate inside the project root, and use the timeout parameter for longer-running verification. This tool should not be used to narrate work; use it to actually inspect or verify the local system state.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "command": PropertySchema(type: "string", description: "The shell command to execute."),
                "timeout": PropertySchema(type: "integer", description: "Timeout in seconds. Default 30, max 120.")
            ],
            required: ["command"]
        ),
        strict: false,
        inputExamples: [
            [
                "command": .string("swift test"),
                "timeout": .int(60)
            ]
        ]
    )

    // MARK: - Web

    public static let webSearch = ToolDefinition(
        name: "web_search",
        description: "Search the web for current documentation, API references, release notes, or other up-to-date technical information. Use this when correctness depends on current external information, such as Apple API changes, library behavior, or recent platform guidance. Form highly specific technical queries instead of vague browsing prompts, and prefer it when internal knowledge may be stale. Results should be treated as grounded context for the next step.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "query": PropertySchema(type: "string", description: "The search query.")
            ],
            required: ["query"]
        ),
        strict: true,
        inputExamples: [
            ["query": .string("iOS 18 SwiftData ModelContext latest API")]
        ]
    )

    public static let deployToTestFlight = ToolDefinition(
        name: "deploy_to_testflight",
        description: "Build and upload the current iOS app to TestFlight using a predefined Fastlane lane in the project directory. Use this only when the user clearly wants to ship or distribute the app and the project is already in a deployable state. This can take several minutes and requires a correctly configured signing and Fastlane environment. If no lane is provided, the default beta lane is used.",
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "lane": PropertySchema(type: "string", description: "Optional Fastlane lane name. Defaults to beta.")
            ],
            required: []
        ),
        strict: false
    )
}
