// SessionTemplateEngine.swift
// Studio.92 — CommandCenter
// Discovers, parses, and surfaces prebuilt session templates from .studio92/templates/ TOML files.
// Monitors the template directory for live reloading on save (handles atomic saves via FSEvents).

import Foundation
import Observation

// MARK: - Session Template

struct SessionTemplate: Identifiable, Hashable, Sendable {
    var id: String { fileName }
    let fileName: String
    let name: String
    let description: String
    let objective: String
    let icon: String
    let tags: [String]
    let isBuiltin: Bool

    func toSuggestion() -> AgenticSuggestion {
        AgenticSuggestion(
            id: fileName,
            title: name,
            prompt: objective,
            symbolName: icon,
            templateDescription: description
        )
    }
}

// MARK: - Template Engine

@MainActor
@Observable
final class SessionTemplateEngine {

    // MARK: - Published State

    private(set) var templates: [SessionTemplate] = []
    private(set) var isLoaded = false

    // MARK: - Internal

    @ObservationIgnored private var workspacePath: String
    @ObservationIgnored private var watcher: PathEventMonitor?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private var templatesDirectoryURL: URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(".studio92/templates", isDirectory: true)
    }

    // MARK: - Lifecycle

    init(workspacePath: String) {
        self.workspacePath = workspacePath
    }

    func start() {
        loadTemplates()
        startWatching()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        watcher?.stop()
        watcher = nil
    }

    func updateWorkspace(_ newPath: String) {
        let normalized = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != workspacePath else { return }
        stop()
        workspacePath = normalized
        start()
    }

    // MARK: - Template Access

    func template(named name: String) -> SessionTemplate? {
        templates.first { $0.name == name }
    }

    func templates(taggedWith tag: String) -> [SessionTemplate] {
        templates.filter { $0.tags.contains(tag) }
    }

    var suggestions: [AgenticSuggestion] {
        templates.map { $0.toSuggestion() }
    }

    // MARK: - Loading

    private func loadTemplates() {
        let directoryURL = templatesDirectoryURL
        var parsed: [SessionTemplate] = []

        if FileManager.default.fileExists(atPath: directoryURL.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for fileURL in contents where fileURL.pathExtension == "toml" {
                guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                if let template = Self.parseTemplate(raw: raw, fileName: fileURL.deletingPathExtension().lastPathComponent) {
                    parsed.append(template)
                }
            }
        }

        // Merge builtins: only include builtins whose names don't conflict with user templates.
        let userNames = Set(parsed.map(\.name))
        for builtin in Self.builtinTemplates where !userNames.contains(builtin.name) {
            parsed.append(builtin)
        }

        // Stable sort: user templates first (alphabetical), then builtins (alphabetical).
        parsed.sort { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return !lhs.isBuiltin }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        templates = parsed
        isLoaded = true
    }

    // MARK: - File Watching

    private func startWatching() {
        watcher?.stop()

        // Ensure the directory exists so FSEvents has something to monitor.
        let directoryPath = templatesDirectoryURL.path
        if !FileManager.default.fileExists(atPath: directoryPath) {
            try? FileManager.default.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true
            )
        }

        watcher = PathEventMonitor(
            path: directoryPath,
            label: "com.studio92.templates"
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReload()
            }
        }
        watcher?.start()
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            loadTemplates()
        }
    }

    // MARK: - TOML Parsing

    static func parseTemplate(raw: String, fileName: String) -> SessionTemplate? {
        var fields: [String: String] = [:]
        var tagsArray: [String] = []

        var currentKey: String?
        var multilineBuffer: String?

        for rawLine in raw.components(separatedBy: .newlines) {
            // Handle multiline string continuation.
            if let key = currentKey, multilineBuffer != nil {
                if rawLine.contains("\"\"\"") {
                    // Closing triple-quote: finalize.
                    let closingPart = rawLine.components(separatedBy: "\"\"\"").first ?? ""
                    multilineBuffer! += closingPart
                    fields[key] = multilineBuffer!
                    currentKey = nil
                    multilineBuffer = nil
                } else {
                    multilineBuffer! += rawLine + "\n"
                }
                continue
            }

            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip comments.
            if let commentIndex = line.firstIndex(of: "#") {
                // Only strip if not inside a string.
                let beforeComment = String(line[..<commentIndex])
                let quoteCount = beforeComment.filter { $0 == "\"" }.count
                if quoteCount % 2 == 0 {
                    line = beforeComment.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            guard !line.isEmpty else { continue }

            // Skip section headers — templates are flat.
            if line.hasPrefix("[") && line.hasSuffix("]") { continue }

            guard let separator = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Handle tags array.
            if key == "tags" && value.hasPrefix("[") {
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                tagsArray = value
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    .filter { !$0.isEmpty }
                continue
            }

            // Handle triple-quoted multiline strings.
            if value.hasPrefix("\"\"\"") {
                let afterOpening = String(value.dropFirst(3))
                if afterOpening.contains("\"\"\"") {
                    // Single-line triple-quoted: """content"""
                    let content = afterOpening.components(separatedBy: "\"\"\"").first ?? ""
                    fields[key] = content
                } else {
                    // Start of multiline.
                    currentKey = key
                    multilineBuffer = afterOpening.isEmpty ? "" : afterOpening + "\n"
                }
                continue
            }

            // Regular quoted string.
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }

        guard let name = fields["name"],
              let description = fields["description"],
              let objective = fields["objective"] else {
            return nil
        }

        let icon = fields["icon"] ?? "sparkles"

        return SessionTemplate(
            fileName: fileName,
            name: name,
            description: description,
            objective: objective,
            icon: icon,
            tags: tagsArray,
            isBuiltin: false
        )
    }

    // MARK: - Builtin Templates

    static let builtinTemplates: [SessionTemplate] = [
        SessionTemplate(
            fileName: "_builtin_audit",
            name: "Audit Codebase",
            description: "Map the workspace architecture, surface risks, and identify structural issues.",
            objective: "Audit this workspace and map the key architecture before making changes.",
            icon: StudioSymbol.resolve("scope", "magnifyingglass"),
            tags: ["discovery"],
            isBuiltin: true
        ),
        SessionTemplate(
            fileName: "_builtin_scaffold",
            name: "Scaffold New UI",
            description: "Generate production-ready SwiftUI screens with clean structure.",
            objective: "Scaffold a native iOS app with SwiftUI, clean structure, and production-ready screens.",
            icon: StudioSymbol.resolve("sparkles.rectangle.stack", "hammer.fill"),
            tags: ["build"],
            isBuiltin: true
        ),
        SessionTemplate(
            fileName: "_builtin_review",
            name: "Review Architecture",
            description: "Deep review of the current codebase for bottlenecks and design drift.",
            objective: "Review the current architecture for bottlenecks, HIG drift, and structural risks.",
            icon: StudioSymbol.resolve("checklist.checked", "checklist"),
            tags: ["review"],
            isBuiltin: true
        ),
        SessionTemplate(
            fileName: "_builtin_release_prep",
            name: "Production Release Prep",
            description: "Pre-flight check for App Store submission: signing, manifests, metadata.",
            objective: """
            Prepare this project for App Store submission. Check:
            1. Bundle identifier and version strings
            2. Signing and entitlements configuration
            3. Privacy manifest completeness (PrivacyInfo.xcprivacy)
            4. Required App Store metadata and screenshots
            5. Any App Store Review Guideline blockers
            Report a go/no-go verdict with specific remediation steps for any blockers.
            """,
            icon: "shippingbox.fill",
            tags: ["shipping", "review"],
            isBuiltin: true
        ),
        SessionTemplate(
            fileName: "_builtin_security_audit",
            name: "Security Audit",
            description: "Scan for OWASP Top 10 vulnerabilities, hardcoded secrets, and unsafe patterns.",
            objective: """
            Perform a security audit of this codebase. Look specifically for:
            1. Hardcoded API keys, tokens, or secrets
            2. Insecure network requests (non-HTTPS, missing certificate pinning)
            3. SQL injection or command injection vectors
            4. Unsafe file operations (path traversal, symlink attacks)
            5. Retain cycles and memory leaks in async contexts
            6. Missing input validation at system boundaries
            Report findings ranked by severity with file paths and line numbers.
            """,
            icon: "shield.checkerboard",
            tags: ["security", "review"],
            isBuiltin: true
        ),
    ]
}
