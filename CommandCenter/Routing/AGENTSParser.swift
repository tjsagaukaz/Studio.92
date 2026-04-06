// AGENTSParser.swift
// Studio.92 — CommandCenter
// CC-local copy with internal access — mirrors SPM's Manifest/AGENTSParser.swift.

import Foundation

struct AGENTSManifest: Sendable, Equatable {
    let operatingRules: [String]
    let modelRoles: [String: String]
    let workspaceConventions: [String: String]

    init(
        operatingRules: [String] = [],
        modelRoles: [String: String] = [:],
        workspaceConventions: [String: String] = [:]
    ) {
        self.operatingRules = operatingRules
        self.modelRoles = modelRoles
        self.workspaceConventions = workspaceConventions
    }

    var isEmpty: Bool {
        operatingRules.isEmpty && modelRoles.isEmpty && workspaceConventions.isEmpty
    }
}

enum AGENTSParser {

    static func parse(projectRoot: URL) -> AGENTSManifest {
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

    static func parse(markdown: String) -> AGENTSManifest {
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

    private static func extractSections(from markdown: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentHeader: String?
        var currentLines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("##") {
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
        if let header = currentHeader {
            sections[header] = currentLines.joined(separator: "\n")
        }
        return sections
    }

    private static func extractBulletPoints(from body: String) -> [String] {
        var results: [String] = []
        var currentBullet: String?

        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let bullet = parseBulletStart(trimmed) {
                if let prev = currentBullet { results.append(prev) }
                currentBullet = bullet
            } else if !trimmed.isEmpty, let _ = currentBullet {
                currentBullet! += " " + trimmed
            }
        }
        if let prev = currentBullet { results.append(prev) }
        return results
    }

    private static func parseBulletStart(_ line: String) -> String? {
        if (line.hasPrefix("- ") || line.hasPrefix("* ")) && line.count > 2 {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if let dotIdx = line.firstIndex(of: "."),
           dotIdx != line.startIndex,
           line[line.startIndex..<dotIdx].allSatisfy(\.isNumber) {
            let text = line[line.index(after: dotIdx)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private static func extractModelRoles(from body: String) -> [String: String] {
        var roles: [String: String] = [:]
        for bullet in extractBulletPoints(from: body) {
            guard let colonIdx = bullet.firstIndex(of: ":") else { continue }
            let rolesPart = bullet[..<colonIdx]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "")
            let modelPart = bullet[bullet.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "")
            guard !modelPart.isEmpty else { continue }
            let roleNames = rolesPart
                .components(separatedBy: " and ")
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            let cleanModel = modelPart
                .components(separatedBy: ",")
                .first?
                .trimmingCharacters(in: .whitespaces) ?? modelPart
            for role in roleNames { roles[role] = cleanModel }
        }
        return roles
    }

    private static func extractKeyValueBullets(from body: String) -> [String: String] {
        var conventions: [String: String] = [:]
        for bullet in extractBulletPoints(from: body) {
            guard let firstTick = bullet.firstIndex(of: "`") else { continue }
            let afterFirst = bullet.index(after: firstTick)
            guard afterFirst < bullet.endIndex,
                  let secondTick = bullet[afterFirst...].firstIndex(of: "`") else { continue }
            let value = String(bullet[afterFirst..<secondTick])
            let keyPart = bullet[..<firstTick]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
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
