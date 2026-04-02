// ToolDefinitions.swift
// Studio.92 — Agent Council
// Anthropic tool_use schemas for the agentic orchestrator.
// Each tool maps to a handler in ToolExecutor.

import Foundation

public enum AgentTools {

    /// All tools available to the agentic orchestrator.
    public static let all: [ToolDefinition] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
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
        strict: true
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
        strict: true,
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
        strict: true
    )
}
