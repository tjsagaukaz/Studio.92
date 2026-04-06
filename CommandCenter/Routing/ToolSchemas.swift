// ToolSchemas.swift
// Studio.92 — Command Center
// Default tool schema definitions for the agentic bridge — extracted from AgenticBridgeTypes.swift.

import Foundation

enum DefaultToolSchemas {

    private static func closedObjectSchema(
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    static let explorerTools: [[String: Any]] = [fileRead, listFiles, webSearch]
    static let reviewerTools: [[String: Any]] = [
        fileRead, fileWrite, filePatch, listFiles, terminal, webSearch
    ]
    static let leanOperator: [[String: Any]] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
        delegateToExplorer,
        delegateToReviewer,
        terminal,
        webSearch
    ]
    static let all: [[String: Any]] = [
        fileRead,
        fileWrite,
        filePatch,
        listFiles,
        delegateToExplorer,
        delegateToReviewer,
        delegateToWorktree,
        terminal,
        webSearch,
        deployToTestFlight
    ]

    static let fileRead: [String: Any] = [
        "name": "file_read",
        "description": "Read the contents of a UTF-8 text file at the given path and return the file contents. Use this when you need grounded source context before making a change or when you need to verify how an existing implementation works. Prefer targeted reads of the most relevant files instead of broad repository sweeps. This tool returns raw file text and should not be used for directories or binary assets.",
        "strict": true,
        "input_examples": [
            ["path": "Sources/AgentCouncil/AgentCouncil.swift"]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "path": ["type": "string", "description": "File path to read."]
            ],
            required: ["path"]
        )
    ]

    static let fileWrite: [String: Any] = [
        "name": "file_write",
        "description": "Create a new file or fully overwrite an existing UTF-8 text file with the provided contents. Use this when creating a new source file or intentionally replacing the entire contents of a file after you already understand the target. Do not use this for tiny edits when file_patch would be safer and more precise. Intermediate directories are created automatically when needed.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "path":    ["type": "string", "description": "File path to write."],
                "content": ["type": "string", "description": "File content."]
            ] as [String: Any],
            required: ["path", "content"]
        )
    ]

    static let filePatch: [String: Any] = [
        "name": "file_patch",
        "description": "Apply a precise search-and-replace edit to an existing file. Use this for focused modifications when you know the exact old text that should be replaced, and prefer it over file_write for small or surgical edits. The old_string must match exactly one location in the file; if it matches zero or multiple locations, the patch will fail and you should provide more specific context. This tool is ideal for anchored edits that should not disturb unrelated surrounding code.",
        "strict": true,
        "input_examples": [
            [
                "path": "Sources/App/FeatureView.swift",
                "old_string": "Text(\"Hello\")",
                "new_string": "Text(\"Hello, world\")"
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "path":       ["type": "string", "description": "File path."],
                "old_string": ["type": "string", "description": "Exact text to find."],
                "new_string": ["type": "string", "description": "Replacement text."]
            ] as [String: Any],
            required: ["path", "old_string", "new_string"]
        )
    ]

    static let listFiles: [String: Any] = [
        "name": "list_files",
        "description": "List the files and directories at the provided path, optionally walking recursively up to a shallow depth. Use this to orient yourself in a focused area of the project when you do not yet know the exact filename you need. Prefer listing a relevant subdirectory instead of scanning the whole repository. Directory names are returned with a trailing slash.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "path": ["type": "string", "description": "Directory path."]
            ] as [String: Any],
            required: ["path"]
        )
    ]

    static let delegateToExplorer: [String: Any] = [
        "name": "delegate_to_explorer",
        "description": "Spawn a focused background codebase explorer that stays read-only and gathers broad context before you write code. Use this when the task requires tracing data flow across multiple files, comparing implementations in several directories, or investigating a subsystem without polluting your main context window. Provide a concrete objective and the most relevant target directories so the explorer can stay narrow. The explorer returns only a concise, high-density findings summary, not raw file transcripts.",
        "strict": true,
        "input_examples": [
            [
                "objective": "Trace how session state flows from login to the main dashboard.",
                "target_directories": ["Sources/App/Auth", "Sources/App/Session"]
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "objective": ["type": "string", "description": "What the explorer should learn or trace through the codebase."],
                "target_directories": [
                    "type": "array",
                    "description": "Relevant directories for the explorer to inspect first.",
                    "items": ["type": "string", "description": "Absolute or project-relative directory path."]
                ]
            ] as [String: Any],
            required: ["objective", "target_directories"]
        )
    ]

    static let delegateToReviewer: [String: Any] = [
        "name": "delegate_to_reviewer",
        "description": "Spawn a specialized read-only reviewer to audit specific files for correctness, performance, security, and strict Apple-platform quality issues. Use this after meaningful code changes, when you want a second pass on risky files, or when you need a terse audit focused on one area. Provide only the files that actually matter and a concrete focus area so the reviewer stays sharp. The reviewer returns a short structured findings list rather than long explanations or raw code dumps.",
        "strict": true,
        "input_examples": [
            [
                "files_to_review": ["Sources/App/ContentView.swift", "Sources/App/AppModel.swift"],
                "focus_area": "Concurrency safety and HIG compliance"
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "files_to_review": [
                    "type": "array",
                    "description": "Files the reviewer should audit.",
                    "items": ["type": "string", "description": "Absolute or project-relative file path."]
                ],
                "focus_area": ["type": "string", "description": "The audit lens, such as performance, security, architecture, or Apple HIG compliance."]
            ] as [String: Any],
            required: ["files_to_review", "focus_area"]
        )
    ]

    static let delegateToWorktree: [String: Any] = [
        "name": "delegate_to_worktree",
        "description": "Create an isolated git worktree under .studio92/worktrees and hand a longer-running task to a background GPT-5.4 mini worker. Use this when the task should continue in parallel without polluting the main workspace, especially for broad refactors, audits, release prep, or deep implementation passes. Provide a branch name, a target worktree directory name, and the exact task prompt the background worker should execute.",
        "strict": false,
        "input_examples": [
            [
                "branch_name": "studio92/app-store-audit",
                "target_directory": "app-store-audit",
                "task_prompt": "Audit the iOS app for current App Store metadata, privacy manifest, and signing gaps."
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "branch_name": ["type": "string", "description": "Branch to create for the isolated worktree job."],
                "target_directory": ["type": "string", "description": "Folder name inside .studio92/worktrees for this background job."],
                "task_prompt": ["type": "string", "description": "The exact task the background worker should complete."]
            ] as [String: Any],
            required: ["branch_name", "task_prompt"]
        )
    ]

    static let terminal: [String: Any] = [
        "name": "terminal",
        "description": "Ask the terminal executor to inspect, build, test, or verify the workspace. Use this when shell output would reduce guesswork or validate a change. Describe the outcome you want, provide any important context, and the terminal executor will choose the exact commands. This tool should not be used to narrate work; use it to actually inspect or verify the local system state.",
        "strict": false,
        "input_examples": [
            [
                "objective": "Run the test suite and report any compiler or test failures",
                "timeout": 60
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "objective": ["type": "string", "description": "What you want the terminal executor to accomplish."],
                "context": ["type": "string", "description": "Optional context that will help the terminal executor choose commands."],
                "starting_command": ["type": "string", "description": "Optional initial shell command to try first if you already know a likely starting point."],
                "command": ["type": "string", "description": "Backward-compatible alias for starting_command."],
                "timeout": ["type": "integer", "description": "Timeout in seconds (max 120)."]
            ] as [String: Any],
            required: ["objective"]
        )
    ]

    static let webSearch: [String: Any] = [
        "name": "web_search",
        "description": "Search the web for current documentation, API references, release notes, or other up-to-date technical information. Use this when correctness depends on current external information, such as Apple API changes, library behavior, or recent platform guidance. Form highly specific technical queries instead of vague browsing prompts, and prefer it when internal knowledge may be stale. Results should be treated as grounded context for the next step.",
        "strict": true,
        "input_examples": [
            ["query": "iOS 18 SwiftData ModelContext latest API"]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "query": ["type": "string", "description": "Search query."]
            ] as [String: Any],
            required: ["query"]
        )
    ]

    static let deployToTestFlight: [String: Any] = [
        "name": "deploy_to_testflight",
        "description": "Build and upload the current iOS app to TestFlight using a predefined Fastlane lane in the project directory. Use this only when the user clearly wants to ship or distribute the app and the project is already in a deployable state. This can take several minutes and requires a correctly configured signing and Fastlane environment. If no lane is provided, the default beta lane is used.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "lane": ["type": "string", "description": "Optional Fastlane lane name. Defaults to beta."]
            ] as [String: Any],
            required: ["lane"]
        )
    ]
}
