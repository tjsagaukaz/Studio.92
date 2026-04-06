// CodeDiffEngine.swift
// Studio.92 — Command Center

import SwiftUI
import AppKit

enum CodeDiffPreviewState: Equatable {
    case idle
    case loading
    case ready(CodeDiffSession)
    case archived(String?)
    case failed(String)

    static func prepare(code: String, targetHint: String?, packageRoot: String) -> CodeDiffPreviewState {
        guard let targetURL = CodeTargetResolver.resolveTargetURL(
            targetHint: targetHint,
            packageRoot: packageRoot
        ) else {
            return .failed("I couldn’t locate a target file for this code block.")
        }

        let currentSource: String
        if FileManager.default.fileExists(atPath: targetURL.path) {
            currentSource = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
        } else {
            currentSource = ""
        }

        return .ready(
            CodeDiffSession(
                targetURL: targetURL,
                targetDisplayName: CodeTargetResolver.displayName(for: targetURL, packageRoot: packageRoot),
                originalSource: currentSource,
                proposedSource: code,
                diffLines: DiffEngine.makeLines(
                    currentSource: currentSource,
                    proposedSource: code,
                    targetDisplayName: CodeTargetResolver.displayName(for: targetURL, packageRoot: packageRoot)
                ),
                isNewFile: !FileManager.default.fileExists(atPath: targetURL.path)
            )
        )
    }
}

extension CodeDiffPreviewState {
    var viewportSubtitle: String {
        switch self {
        case .ready(let session):
            return session.targetDisplayName
        case .archived:
            return "Grounded epoch diff"
        case .failed:
            return "No target file"
        case .idle, .loading:
            return "Resolving target"
        }
    }

    var supportsApply: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

struct CodeDiffSession: Equatable {
    let targetURL: URL
    let targetDisplayName: String
    let originalSource: String
    let proposedSource: String
    let diffLines: [DiffLine]
    let isNewFile: Bool
}

struct DiffLine: Identifiable, Equatable {

    enum Kind: Equatable {
        case header
        case context
        case addition
        case removal
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

struct DiffPreviewView: View {

    let session: CodeDiffSession

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(session.diffLines) { line in
                    DiffLineRow(line: line)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffLineRow: View {

    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // Gutter: old/new line numbers
            HStack(spacing: 0) {
                gutterNumber(line.oldLineNumber)
                gutterNumber(line.newLineNumber)
            }
            .frame(width: 72)

            // Symbol column
            Text(symbol)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(symbolColor)
                .frame(width: 18, alignment: .center)

            // Content
            Group {
                if line.kind == .removal {
                    Text(line.text.isEmpty ? " " : line.text)
                        .strikethrough(true, color: DiffPalette.removal.opacity(0.55))
                } else {
                    Text(line.text.isEmpty ? " " : line.text)
                }
            }
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(textColor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)
        }
        .padding(.vertical, 2)
        .background(rowBackground)
    }

    // MARK: - Helpers

    private var symbol: String {
        switch line.kind {
        case .header:   return "⌁"
        case .context:  return " "
        case .addition: return "+"
        case .removal:  return "−"
        }
    }

    private var symbolColor: Color {
        switch line.kind {
        case .header:   return StudioColorTokens.Syntax.diffHeader.opacity(0.8)
        case .context:  return Color.clear
        case .addition: return DiffPalette.addition
        case .removal:  return DiffPalette.removal
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .header:   return StudioColorTokens.Syntax.diffHeader.opacity(0.7)
        case .context:  return Color(hex: "#7E8794")   // Muted Graphite — context dims to background
        case .addition: return DiffPalette.addition.opacity(0.9)
        case .removal:  return DiffPalette.removal.opacity(0.65)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch line.kind {
        case .header:
            Color.white.opacity(0.03)
        case .context:
            Color.clear
        case .addition:
            DiffPalette.addition.opacity(0.10)
        case .removal:
            DiffPalette.removal.opacity(0.10)
        }
    }

    private func gutterNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundStyle(Color(hex: "#7E8794").opacity(0.4))
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 2)
    }
}

// MARK: - Diff Palette

private enum DiffPalette {
    /// Volt Mint — #86EFAC
    static let addition = Color(nsColor: NSColor(srgbRed: 134/255, green: 239/255, blue: 172/255, alpha: 1))
    /// Cool Red — #FF7373
    static let removal  = Color(nsColor: NSColor(srgbRed: 255/255, green: 115/255, blue: 115/255, alpha: 1))
}

enum DiffEngine {

    static func makeLines(
        currentSource: String,
        proposedSource: String,
        targetDisplayName: String
    ) -> [DiffLine] {
        let oldLines = splitLines(currentSource)
        let newLines = splitLines(proposedSource)
        let diff = newLines.difference(from: oldLines)

        let removals = Dictionary(grouping: diff.removals, by: changeOffset)
        let insertions = Dictionary(grouping: diff.insertions, by: changeOffset)

        var rows: [DiffLine] = [
            DiffLine(id: 0, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: "--- \(targetDisplayName)"),
            DiffLine(id: 1, kind: .header, oldLineNumber: nil, newLineNumber: nil, text: "+++ Proposed")
        ]

        var oldIndex = 0
        var newIndex = 0
        var oldLineNumber = 1
        var newLineNumber = 1
        var rowID = 2

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if let removalGroup = removals[oldIndex], !removalGroup.isEmpty {
                for _ in removalGroup {
                    guard oldIndex < oldLines.count else { break }
                    rows.append(
                        DiffLine(
                            id: rowID,
                            kind: .removal,
                            oldLineNumber: oldLineNumber,
                            newLineNumber: nil,
                            text: oldLines[oldIndex]
                        )
                    )
                    rowID += 1
                    oldIndex += 1
                    oldLineNumber += 1
                }
                continue
            }

            if let insertionGroup = insertions[newIndex], !insertionGroup.isEmpty {
                for _ in insertionGroup {
                    guard newIndex < newLines.count else { break }
                    rows.append(
                        DiffLine(
                            id: rowID,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: newLineNumber,
                            text: newLines[newIndex]
                        )
                    )
                    rowID += 1
                    newIndex += 1
                    newLineNumber += 1
                }
                continue
            }

            if oldIndex < oldLines.count, newIndex < newLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .context,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber,
                        text: oldLines[oldIndex]
                    )
                )
                rowID += 1
                oldIndex += 1
                newIndex += 1
                oldLineNumber += 1
                newLineNumber += 1
            } else if oldIndex < oldLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .removal,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil,
                        text: oldLines[oldIndex]
                    )
                )
                rowID += 1
                oldIndex += 1
                oldLineNumber += 1
            } else if newIndex < newLines.count {
                rows.append(
                    DiffLine(
                        id: rowID,
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber,
                        text: newLines[newIndex]
                    )
                )
                rowID += 1
                newIndex += 1
                newLineNumber += 1
            }
        }

        return rows
    }

    private static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func changeOffset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .remove(let offset, _, _), .insert(let offset, _, _):
            return offset
        }
    }
}

enum CodeDiffWriter {

    static func write(session: CodeDiffSession) -> Result<Void, Error> {
        let parentDirectory = session.targetURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            try session.proposedSource.write(to: session.targetURL, atomically: true, encoding: .utf8)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

enum CodeTargetResolver {

    private static let allowedExtensions = Set([
        "swift", "m", "mm", "h", "json", "plist", "md", "txt", "py", "sh", "yaml", "yml"
    ])

    static func extractTargetHint(explicitHint: String?, code: String) -> String? {
        if let explicitHint,
           let normalized = normalizedPathHint(from: explicitHint) {
            return normalized
        }

        for line in code.components(separatedBy: .newlines).prefix(4) {
            if let normalized = normalizedPathHint(from: line) {
                return normalized
            }
        }

        return nil
    }

    static func normalizedPathHint(from text: String) -> String? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("//") {
            candidate = String(candidate.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.hasPrefix("#") {
            candidate = String(candidate.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if candidate.lowercased().hasPrefix("file:") {
            candidate = String(candidate.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if candidate.lowercased().hasPrefix("path:") {
            candidate = String(candidate.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'*/ "))
        guard !candidate.isEmpty else { return nil }

        let url = URL(fileURLWithPath: candidate)
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return nil }

        if candidate.contains("/") || candidate.contains("\\") || candidate.contains(".") {
            return candidate.replacingOccurrences(of: "\\", with: "/")
        }

        return nil
    }

    static func resolveTargetURL(targetHint: String?, packageRoot: String) -> URL? {
        guard let targetHint else { return nil }

        if targetHint.hasPrefix("/") {
            return URL(fileURLWithPath: targetHint)
        }

        let rootURL = URL(fileURLWithPath: packageRoot, isDirectory: true)
        let relativeCandidate = rootURL.appendingPathComponent(targetHint)
        if FileManager.default.fileExists(atPath: relativeCandidate.path) || targetHint.contains("/") {
            return relativeCandidate
        }

        let basename = (targetHint as NSString).lastPathComponent
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var matches: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == basename else { continue }
            matches.append(url)
            if matches.count > 1 {
                break
            }
        }

        if matches.count == 1 {
            return matches[0]
        }

        if matches.count > 1 {
            return nil
        }

        return targetHint.contains("/") ? relativeCandidate : nil
    }

    static func displayName(for url: URL, packageRoot: String) -> String {
        let rootPath = URL(fileURLWithPath: packageRoot, isDirectory: true).path
        let path = url.path
        if path.hasPrefix(rootPath) {
            let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? url.lastPathComponent : relative
        }
        return path
    }
}

enum CodeSyntaxHighlighter {

    /// Languages that should render as raw text — no tokenization.
    private static let plainTextLanguages: Set<String> = [
        "text", "plaintext", "plain", "txt",
        "prompt", "markdown", "md",
        "output", "log", "console",
        "toml", "yaml", "yml", "json",
        "bash", "sh", "zsh", "shell"
    ]

    static func highlight(code: String, language: String?) -> AttributedString {
        let syn = StudioColorTokens.Syntax.self
        let normalizedLang = language?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""

        // Raw-text bypass: uniform silver, zero tokenization
        if normalizedLang.isEmpty || plainTextLanguages.contains(normalizedLang) {
            return AttributedString(NSAttributedString(
                string: code,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(srgbRed: 226/255, green: 232/255, blue: 240/255, alpha: 1) // #E2E8F0
                ]
            ))
        }

        let attributed = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: syn.plain
            ]
        )

        let nsRange = NSRange(location: 0, length: (code as NSString).length)

        // Comments — Muted Graphite (applied first so later passes can skip)
        let commentRegex = try? NSRegularExpression(pattern: #"//.*$"#, options: [.anchorsMatchLines])
        commentRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: syn.comment, range: match.range)
        }

        // Strings — Volt Mint
        let stringRegex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*""#, options: [])
        stringRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: syn.string, range: match.range)
        }

        // Keywords — Electric Cyan
        let keywordPattern = #"\b(struct|class|enum|protocol|extension|var|let|func|import|return|if|else|guard|switch|case|default|for|while|repeat|break|continue|await|async|throws|throw|try|catch|some|any|where|in|is|as|self|Self|nil|true|false|mutating|static|private|public|internal|fileprivate|open|override|final|weak|unowned|lazy|typealias|associatedtype|init|deinit|subscript|get|set|willSet|didSet|inout|@[A-Za-z]+)\b"#
        let keywordRegex = try? NSRegularExpression(pattern: keywordPattern, options: [])
        keywordRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: syn.keyword, range: match.range)
        }

        // Types / classes — Icy Violet (capitalized identifiers)
        let typeRegex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, options: [])
        typeRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: syn.type, range: match.range)
        }

        // Functions — Icy Violet (identifier followed by open-paren)
        let functionRegex = try? NSRegularExpression(pattern: #"\b([a-z_][A-Za-z0-9_]*)\s*(?=\()"#, options: [])
        functionRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            let nameRange = match.range(at: 1)
            guard nameRange.location != NSNotFound else { return }
            let name = (code as NSString).substring(with: nameRange)
            let keywordCalls: Set<String> = ["if", "guard", "switch", "for", "while", "catch", "return", "try", "await", "throw", "repeat"]
            guard !keywordCalls.contains(name) else { return }
            attributed.addAttribute(.foregroundColor, value: syn.function, range: nameRange)
        }

        // Number literals — Volt Mint
        let numberRegex = try? NSRegularExpression(pattern: #"\b\d[\d_.]*\b"#, options: [])
        numberRegex?.enumerateMatches(in: code, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            attributed.addAttribute(.foregroundColor, value: syn.string, range: match.range)
        }

        return AttributedString(attributed)
    }
}

enum CodeApplyFeedback {

    static func performSuccess() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}

