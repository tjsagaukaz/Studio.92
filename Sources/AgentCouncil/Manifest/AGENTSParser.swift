// AGENTSParser.swift
// Studio.92 — Agent Council
// Extracts structured sections from AGENTS.md.
// Defensive and fuzzy: tolerates extra hashes, case variations,
// both dash and asterisk bullets, and missing sections.

import Foundation

/// Structured representation of an AGENTS.md file.
public struct AGENTSManifest: Sendable, Equatable {
    /// Bullet points from the "Operating Rules" section.
    public let operatingRules: [String]
    /// Role name → model name pairs from the "Model Roles" section.
    public let modelRoles: [String: String]
    /// Key → path pairs from the "Workspace Conventions" section.
    public let workspaceConventions: [String: String]

    public init(
        operatingRules: [String] = [],
        modelRoles: [String: String] = [:],
        workspaceConventions: [String: String] = [:]
    ) {
        self.operatingRules = operatingRules
        self.modelRoles = modelRoles
        self.workspaceConventions = workspaceConventions
    }

    /// True when no usable content was extracted.
    public var isEmpty: Bool {
        operatingRules.isEmpty && modelRoles.isEmpty && workspaceConventions.isEmpty
    }
}

public enum AGENTSParser {

    // MARK: - Public API

    /// Parse an AGENTS.md file from the given project root.
    /// Returns an empty manifest (not nil, not a crash) if the file is missing or malformed.
    public static func parse(projectRoot: URL) -> AGENTSManifest {
        let candidates = [
            projectRoot.appendingPathComponent("AGENTS.md"),
            projectRoot.appendingPathComponent("agents.md"),
            projectRoot.appendingPathComponent(".agents.md")
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return AGENTSManifest()
        }
        return parse(markdown: content)
    }

    /// Parse raw AGENTS.md markdown content.
    public static func parse(markdown: String) -> AGENTSManifest {
        let sections = extractSections(from: markdown)

        let operatingRules = sections["operating rules"].map(extractBulletPoints) ?? []
        let modelRoles = sections["model roles"].map(extractModelRoles) ?? [:]
        let workspaceConventions = sections["workspace conventions"].map(extractKeyValueBullets) ?? [:]

        return AGENTSManifest(
            operatingRules: operatingRules,
            modelRoles: modelRoles,
            workspaceConventions: workspaceConventions
        )
    }

    // MARK: - Section Extraction

    /// Split markdown into sections keyed by lowercased header text.
    /// Handles ##, ###, extra whitespace, and mixed casing.
    private static func extractSections(from markdown: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentHeader: String?
        var currentLines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match any ## or ### header (strip leading hashes and whitespace).
            if trimmed.hasPrefix("##") {
                // Flush previous section.
                if let header = currentHeader {
                    sections[header] = currentLines.joined(separator: "\n")
                }
                let headerText = trimmed
                    .drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                currentHeader = headerText
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        // Flush final section.
        if let header = currentHeader {
            sections[header] = currentLines.joined(separator: "\n")
        }

        return sections
    }

    // MARK: - Bullet Point Extraction

    /// Extract bullet points from a section body.
    /// Tolerates -, *, and numbered lists (1., 2., etc.).
    private static func extractBulletPoints(from body: String) -> [String] {
        var results: [String] = []
        var currentBullet: String?

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let bullet = parseBulletStart(trimmed) {
                // Flush previous multi-line bullet.
                if let prev = currentBullet {
                    results.append(prev)
                }
                currentBullet = bullet
            } else if !trimmed.isEmpty, let _ = currentBullet {
                // Continuation line of a multi-line bullet.
                currentBullet! += " " + trimmed
            }
        }
        // Flush last bullet.
        if let prev = currentBullet {
            results.append(prev)
        }

        return results
    }

    /// If the line starts with a bullet marker (-, *, or N.), return the text after it.
    private static func parseBulletStart(_ line: String) -> String? {
        // Dash or asterisk bullet: "- text" or "* text"
        if (line.hasPrefix("- ") || line.hasPrefix("* ")) && line.count > 2 {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        // Numbered list: "1. text", "2. text", etc.
        if let dotIdx = line.firstIndex(of: "."),
           dotIdx != line.startIndex,
           line[line.startIndex..<dotIdx].allSatisfy(\.isNumber) {
            let afterDot = line[line.index(after: dotIdx)...]
            let text = afterDot.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Model Role Extraction

    /// Parse model roles from lines like "- `Plan` and `Review`: `Claude Sonnet 4.6`"
    /// Extracts the role label(s) and model name, stripping backticks.
    private static func extractModelRoles(from body: String) -> [String: String] {
        var roles: [String: String] = [:]

        for bullet in extractBulletPoints(from: body) {
            // Split on the first colon to get "role label(s)" : "model name"
            guard let colonIdx = bullet.firstIndex(of: ":") else { continue }
            let rolesPart = bullet[..<colonIdx]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "")
            let modelPart = bullet[bullet.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "")

            guard !modelPart.isEmpty else { continue }

            // Handle "Plan and Review" → two separate role keys.
            let roleNames = rolesPart
                .components(separatedBy: " and ")
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }

            // Strip trailing qualifiers after comma in model part
            // e.g. "GPT-5.4 mini, escalate to GPT-5.4 when..." → "GPT-5.4 mini"
            let cleanModel = modelPart
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? modelPart

            for role in roleNames {
                roles[role] = cleanModel
            }
        }

        return roles
    }

    // MARK: - Key-Value Bullet Extraction

    /// Parse workspace conventions from lines like "- Background sessions live in `.studio92/sessions/`"
    /// Extracts the key phrase and the backtick-wrapped path.
    private static func extractKeyValueBullets(from body: String) -> [String: String] {
        var conventions: [String: String] = [:]

        for bullet in extractBulletPoints(from: body) {
            // Find backtick-wrapped values.
            guard let firstTick = bullet.firstIndex(of: "`") else { continue }
            let afterFirst = bullet.index(after: firstTick)
            guard afterFirst < bullet.endIndex,
                  let secondTick = bullet[afterFirst...].firstIndex(of: "`") else { continue }
            let value = String(bullet[afterFirst..<secondTick])

            // Use the text before "live in" / "default" / the backtick as the key.
            let keyPart = bullet[..<firstTick]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()

            // Clean trailing connectors like "live in", "lives in", "default to"
            let cleanKey = keyPart
                .replacingOccurrences(of: " live in", with: "")
                .replacingOccurrences(of: " lives in", with: "")
                .replacingOccurrences(of: " default to", with: "")
                .trimmingCharacters(in: .whitespaces)

            if !cleanKey.isEmpty && !value.isEmpty {
                conventions[cleanKey] = value
            }
        }

        return conventions
    }
}
