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

    static let explorerTools: [[String: Any]] = [
        fileRead, listFiles, grepSearch, semanticSearch, findSymbol, findUsages, webSearch, webFetch, gitStatus, gitDiff
    ]
    static let reviewerTools: [[String: Any]] = [
        fileRead, fileWrite, filePatch, listFiles, grepSearch, semanticSearch, findSymbol, findUsages, terminal, webSearch, webFetch,
        xcodeBuild, xcodeTest, gitStatus, gitDiff
    ]
    static let leanOperator: [[String: Any]] = [
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
        webFetch,
        xcodeBuild,
        xcodeTest,
        screenshotSimulator,
        gitStatus,
        gitDiff,
        gitCommit
    ]
    static let all: [[String: Any]] = [
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
        delegateToWorktree,
        terminal,
        webSearch,
        webFetch,
        deployToTestFlight,
        screenshotSimulator,
        xcodeBuild,
        xcodeTest,
        xcodePreview,
        multimodalAnalyze,
        gitStatus,
        gitDiff,
        gitCommit,
        simulatorLaunchApp
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

    static let grepSearch: [String: Any] = [
        "name": "grep_search",
        "description": "Run an exact workspace search against current on-disk files and return precise path, line, and column matches. Use this when you know a literal string or regex to search for and want deterministic, bounded results without reading whole files. This is safer than broad file reads because it returns only the matching lines and a small amount of local context.",
        "strict": false,
        "input_examples": [
            [
                "query": "ExecutionLoopEngine",
                "path": "CommandCenter/Execution",
                "max_results": 25
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "query": ["type": "string", "description": "Exact string or regex to search for."],
                "is_regexp": ["type": "boolean", "description": "Interpret query as a regular expression. Defaults to false."],
                "case_sensitive": ["type": "boolean", "description": "Use case-sensitive matching. Defaults to false."],
                "path": ["type": "string", "description": "Optional file or directory path to search within."],
                "paths": [
                    "type": "array",
                    "description": "Optional list of file or directory paths to search within.",
                    "items": ["type": "string", "description": "Absolute or project-relative path."]
                ],
                "max_results": ["type": "integer", "description": "Maximum number of matches to return. Defaults to 50, max 500."],
                "context_lines": ["type": "integer", "description": "Number of context lines to include before and after each match. Defaults to 1, max 5."]
            ] as [String: Any],
            required: ["query"]
        )
    ]

    static let semanticSearch: [String: Any] = [
        "name": "semantic_search",
        "description": "Run a structured semantic retrieval pass over the incrementally indexed workspace using SQLite FTS over declaration-aware Swift chunks. Use this when the query is conceptual, architectural, or pattern-based and exact token matching would miss relevant code. Results are deterministic and include ranked chunks with path, line range, summary, and snippet.",
        "strict": false,
        "input_examples": [
            [
                "query": "streaming pipeline orchestration",
                "path": "CommandCenter/Execution",
                "max_results": 8
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "query": ["type": "string", "description": "Conceptual or architectural search query."],
                "path": ["type": "string", "description": "Optional file or directory path to constrain retrieval."],
                "paths": [
                    "type": "array",
                    "description": "Optional list of file or directory paths to constrain retrieval.",
                    "items": ["type": "string", "description": "Absolute or project-relative path."]
                ],
                "max_results": ["type": "integer", "description": "Maximum number of ranked chunks to return. Defaults to 12, max 50."]
            ] as [String: Any],
            required: ["query"]
        )
    ]

    static let findSymbol: [String: Any] = [
        "name": "find_symbol",
        "description": "Resolve indexed workspace symbols by semantic identity using IndexStoreDB canonical occurrences, then validate returned definitions with SourceKit. Use this when you need a real symbol definition rather than a text match. Results are deterministic and include USR, file, line, and column.",
        "strict": false,
        "input_examples": [
            [
                "query": "RepositoryMonitor",
                "path": "CommandCenter/Workspace",
                "max_results": 5
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "query": ["type": "string", "description": "Symbol name or name fragment to resolve."],
                "path": ["type": "string", "description": "Optional file or directory path to constrain symbol resolution."],
                "paths": [
                    "type": "array",
                    "description": "Optional list of file or directory paths to constrain symbol resolution.",
                    "items": ["type": "string", "description": "Absolute or project-relative path."]
                ],
                "max_results": ["type": "integer", "description": "Maximum number of symbols to return. Defaults to 12, max 50."]
            ] as [String: Any],
            required: ["query"]
        )
    ]

    static let findUsages: [String: Any] = [
        "name": "find_usages",
        "description": "Find semantic symbol occurrences using IndexStoreDB USRs. Resolve the symbol either from an explicit USR or from an exact file, line, and column validated by SourceKit prepare-rename. Use this for real cross-file usages and call sites, not text-based references.",
        "strict": false,
        "input_examples": [
            [
                "path": "CommandCenter/Workspace/RepositoryMonitor.swift",
                "line": 5,
                "column": 13,
                "max_results": 50
            ]
        ],
        "input_schema": closedObjectSchema(
            properties: [
                "usr": ["type": "string", "description": "Optional Unified Symbol Resolution string. If omitted, path + line + column are required."],
                "path": ["type": "string", "description": "File path containing the target symbol when resolving by location."],
                "line": ["type": "integer", "description": "1-based line containing the target symbol when resolving by location."],
                "column": ["type": "integer", "description": "1-based UTF-8 column containing the target symbol when resolving by location."],
                "paths": [
                    "type": "array",
                    "description": "Optional list of file or directory paths to constrain returned usages.",
                    "items": ["type": "string", "description": "Absolute or project-relative path."]
                ],
                "include_definitions": ["type": "boolean", "description": "Include definitions and declarations in the returned occurrences. Defaults to true."],
                "max_results": ["type": "integer", "description": "Maximum number of occurrences to return. Defaults to 200, max 500."]
            ] as [String: Any],
            required: []
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

    // MARK: - Web Fetch

    static let webFetch: [String: Any] = [
        "name": "web_fetch",
        "description": "Fetch the contents of a web page at a given URL and return the body text. Use this when you need to read documentation, release notes, API references, or any specific URL. Prefer web_search when you do not have a specific URL. Returns plain text extracted from the HTML response.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "url": ["type": "string", "description": "The URL to fetch."]
            ] as [String: Any],
            required: ["url"]
        )
    ]

    // MARK: - Screenshot Simulator

    static let screenshotSimulator: [String: Any] = [
        "name": "screenshot_simulator",
        "description": "Capture a screenshot of the currently booted iOS Simulator and return the image path. Use this after a build succeeds to visually confirm the UI renders correctly, or whenever you need to inspect the current simulator state. The screenshot is saved as a PNG and can be passed to multimodal_analyze for detailed inspection.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "device_udid": ["type": "string", "description": "Optional simulator device UDID. Uses the currently selected device if omitted."]
            ] as [String: Any],
            required: []
        )
    ]

    // MARK: - Xcode Build

    static let xcodeBuild: [String: Any] = [
        "name": "xcode_build",
        "description": "Build the project using swift build or xcodebuild and return a structured build report with errors, warnings, and affected files. Use this to verify code compiles after making changes. Defaults to swift build for SPM projects. Provide a scheme for Xcode workspace builds.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "command": ["type": "string", "description": "Build command to run. Defaults to 'swift build'."],
                "scheme": ["type": "string", "description": "Xcode scheme name for xcodebuild. Optional."],
                "configuration": ["type": "string", "description": "Build configuration (Debug/Release). Defaults to Debug."]
            ] as [String: Any],
            required: []
        )
    ]

    // MARK: - Xcode Test

    static let xcodeTest: [String: Any] = [
        "name": "xcode_test",
        "description": "Run the project test suite using swift test or xcodebuild test and return a structured report with pass/fail counts, individual test failures, file locations, and error messages. Use this after code changes to verify nothing is broken.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "command": ["type": "string", "description": "Test command to run. Defaults to 'swift test'."],
                "filter": ["type": "string", "description": "Optional test filter pattern (e.g. 'MyTestClass/testSpecificCase')."]
            ] as [String: Any],
            required: []
        )
    ]

    // MARK: - Xcode Preview

    static let xcodePreview: [String: Any] = [
        "name": "xcode_preview",
        "description": "Build the app, install it on the simulator, launch it, and capture a screenshot — all in one step. Use this as a full end-to-end visual verification after implementing UI changes. Returns the build report and screenshot path.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "scheme": ["type": "string", "description": "Xcode scheme to build. Optional for SPM projects."],
                "device_udid": ["type": "string", "description": "Simulator device UDID. Uses selected device if omitted."],
                "bundle_id": ["type": "string", "description": "App bundle identifier for launch."]
            ] as [String: Any],
            required: ["bundle_id"]
        )
    ]

    // MARK: - Multimodal Analyze

    static let multimodalAnalyze: [String: Any] = [
        "name": "multimodal_analyze",
        "description": "Analyze an image using vision capabilities. Supports screenshots, diagrams, UI mockups, and any visual content. Choose a preset for the analysis style: quick_qa (fast general question), dense_screenshot (full-res UI analysis), ocr_transcribe (extract text), diagram_reasoning (charts/tables), locate_region (find a specific area), deep_inspect (two-pass zoom analysis).",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "image_path": ["type": "string", "description": "Path to the image file to analyze."],
                "question": ["type": "string", "description": "What to analyze or ask about the image."],
                "preset": ["type": "string", "description": "Analysis preset: quick_qa, dense_screenshot, ocr_transcribe, diagram_reasoning, locate_region, deep_inspect. Defaults to quick_qa."]
            ] as [String: Any],
            required: ["image_path", "question"]
        )
    ]

    // MARK: - Git Status

    static let gitStatus: [String: Any] = [
        "name": "git_status",
        "description": "Return the current git repository status including branch name, staged/unstaged/untracked file counts, and a list of changed files with their status codes. Use this to understand the working tree state before committing or to check if there are uncommitted changes.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [:] as [String: Any],
            required: []
        )
    ]

    // MARK: - Git Diff

    static let gitDiff: [String: Any] = [
        "name": "git_diff",
        "description": "Return the git diff output showing changes in the working tree. By default shows unstaged changes; use staged: true to see staged changes. Optionally scope to a specific file path.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "staged": ["type": "boolean", "description": "If true, show staged changes (--cached). Defaults to false."],
                "path": ["type": "string", "description": "Optional file path to scope the diff."]
            ] as [String: Any],
            required: []
        )
    ]

    // MARK: - Git Commit

    static let gitCommit: [String: Any] = [
        "name": "git_commit",
        "description": "Stage the specified files (or all changes) and create a git commit with the given message. Use this only when the user explicitly asks to commit. Always provide a clear, descriptive commit message.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "message": ["type": "string", "description": "The commit message."],
                "files": [
                    "type": "array",
                    "description": "Files to stage before committing. If empty, stages all changes.",
                    "items": ["type": "string", "description": "File path to stage."]
                ],
                "all": ["type": "boolean", "description": "If true, stage all tracked changes (-a). Defaults to false."]
            ] as [String: Any],
            required: ["message"]
        )
    ]

    // MARK: - Simulator Launch App

    static let simulatorLaunchApp: [String: Any] = [
        "name": "simulator_launch_app",
        "description": "Launch an app by bundle identifier on the iOS Simulator. Terminates any running instance first. Use this when you want to launch or relaunch an app without rebuilding.",
        "strict": true,
        "input_schema": closedObjectSchema(
            properties: [
                "bundle_id": ["type": "string", "description": "The app's bundle identifier."],
                "device_udid": ["type": "string", "description": "Simulator device UDID. Uses selected device if omitted."]
            ] as [String: Any],
            required: ["bundle_id"]
        )
    ]
}
