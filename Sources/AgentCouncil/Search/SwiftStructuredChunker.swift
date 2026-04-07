import CryptoKit
import Foundation

enum SwiftStructuredChunker {

    struct ChunkDescriptor: Equatable, Sendable {
        let chunkID: String
        let path: String
        let kind: String
        let symbol: String
        let parentSymbol: String
        let startLine: Int
        let endLine: Int
        let text: String
        let summary: String
        let chunkHash: String
    }

    static func chunkFile(path: String, source: String) -> [ChunkDescriptor] {
        let lines = source.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }

        let lineStates = buildLineStates(lines: lines)
        let declarations = buildDeclarations(path: path, lines: lines, lineStates: lineStates)
        guard !declarations.isEmpty else { return [] }

        let containers = declarations.filter(\.isContainer)
        var duplicateCounts: [String: Int] = [:]
        var chunks: [ChunkDescriptor] = []
        chunks.reserveCapacity(declarations.count)

        for declaration in declarations {
            let parentSymbols = containers
                .filter { $0.startLine < declaration.startLine && $0.endLine >= declaration.endLine }
                .sorted {
                    if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
                    return $0.endLine < $1.endLine
                }
                .map(\.symbol)

            let parentSymbol = parentSymbols.joined(separator: ".")
            let text = lines[(declaration.startLine - 1)...(declaration.endLine - 1)].joined(separator: "\n")
            let summary = buildSummary(for: declaration, parentSymbol: parentSymbol)
            let header = normalizedHeader(lines: lines, declaration: declaration)
            let baseKey = [path, declaration.kind.rawValue, parentSymbol, header].joined(separator: "|")
            let duplicateIndex = duplicateCounts[baseKey, default: 0]
            duplicateCounts[baseKey] = duplicateIndex + 1
            let stableKey = duplicateIndex == 0 ? baseKey : baseKey + "|duplicate:\(duplicateIndex)"
            let chunkID = sha256(stableKey)
            let chunkHash = sha256(text + "\n" + summary)

            chunks.append(
                ChunkDescriptor(
                    chunkID: chunkID,
                    path: path,
                    kind: declaration.kind.rawValue,
                    symbol: declaration.symbol,
                    parentSymbol: parentSymbol,
                    startLine: declaration.startLine,
                    endLine: declaration.endLine,
                    text: text,
                    summary: summary,
                    chunkHash: chunkHash
                )
            )
        }

        return chunks
    }

    private static func buildDeclarations(
        path: String,
        lines: [String],
        lineStates: [LineState]
    ) -> [Declaration] {
        var declarations: [Declaration] = []

        for (index, lineState) in lineStates.enumerated() {
            let lineNumber = index + 1
            let trimmed = lineState.sanitized.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let kind = DeclarationKind.containerKinds.first(where: {
                trimmed.range(of: $0.pattern, options: [.regularExpression]) != nil
            }) {
                guard let symbol = symbolName(in: trimmed, kind: kind) else { continue }
                declarations.append(
                    Declaration(
                        path: path,
                        kind: kind,
                        symbol: symbol,
                        startLine: lineNumber,
                        endLine: declarationEndLine(
                            startLine: lineNumber,
                            startDepth: lineState.startDepth,
                            lines: lines,
                            lineStates: lineStates,
                            declarationKind: kind
                        ),
                        isContainer: true
                    )
                )
                continue
            }

            if let kind = DeclarationKind.callableKinds.first(where: {
                trimmed.range(of: $0.pattern, options: [.regularExpression]) != nil
            }) {
                guard let symbol = symbolName(in: trimmed, kind: kind) else { continue }
                declarations.append(
                    Declaration(
                        path: path,
                        kind: kind,
                        symbol: symbol,
                        startLine: lineNumber,
                        endLine: declarationEndLine(
                            startLine: lineNumber,
                            startDepth: lineState.startDepth,
                            lines: lines,
                            lineStates: lineStates,
                            declarationKind: kind
                        ),
                        isContainer: false
                    )
                )
            }
        }

        return declarations.sorted {
            if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
            if $0.endLine != $1.endLine { return $0.endLine < $1.endLine }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func declarationEndLine(
        startLine: Int,
        startDepth: Int,
        lines: [String],
        lineStates: [LineState],
        declarationKind: DeclarationKind
    ) -> Int {
        let nextPeerLine = nextPeerDeclarationLine(after: startLine, atDepth: startDepth, lineStates: lineStates)
        let searchLimit = (nextPeerLine ?? (lines.count + 1)) - 1

        let bodyStartLine = (startLine...searchLimit).first { lineNumber in
            lineStates[lineNumber - 1].sanitized.contains("{")
        }

        guard let bodyStartLine else {
            return declarationKind.isContainer ? min(searchLimit, lines.count) : max(startLine, searchLimit)
        }

        for lineNumber in bodyStartLine...lines.count {
            let state = lineStates[lineNumber - 1]
            if state.endDepth == startDepth,
               (lineNumber > bodyStartLine || state.sanitized.contains("}")) {
                return lineNumber
            }
        }

        return min(searchLimit, lines.count)
    }

    private static func nextPeerDeclarationLine(
        after startLine: Int,
        atDepth startDepth: Int,
        lineStates: [LineState]
    ) -> Int? {
        guard startLine < lineStates.count else { return nil }

        for index in startLine..<lineStates.count {
            let lineState = lineStates[index]
            guard lineState.startDepth <= startDepth else { continue }
            let trimmed = lineState.sanitized.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if DeclarationKind.allCases.contains(where: { trimmed.range(of: $0.pattern, options: [.regularExpression]) != nil }) {
                return index + 1
            }
        }

        return nil
    }

    private static func symbolName(in line: String, kind: DeclarationKind) -> String? {
        let keyword: String
        switch kind {
        case .classDecl: keyword = "class"
        case .structDecl: keyword = "struct"
        case .enumDecl: keyword = "enum"
        case .actorDecl: keyword = "actor"
        case .protocolDecl: keyword = "protocol"
        case .extensionDecl: keyword = "extension"
        case .funcDecl: keyword = "func"
        case .initDecl: return "init"
        case .subscriptDecl: return "subscript"
        }

        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: keyword) + #"\s+([A-Za-z_][A-Za-z0-9_<>.:]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    private static func buildSummary(for declaration: Declaration, parentSymbol: String) -> String {
        switch declaration.kind {
        case .extensionDecl:
            return "extension \(declaration.symbol)"
        case .initDecl:
            return parentSymbol.isEmpty ? "init" : "init in \(parentSymbol)"
        case .subscriptDecl:
            return parentSymbol.isEmpty ? "subscript" : "subscript in \(parentSymbol)"
        default:
            let qualified = parentSymbol.isEmpty ? declaration.symbol : parentSymbol + "." + declaration.symbol
            return "\(declaration.kind.summaryLabel) \(qualified)"
        }
    }

    private static func normalizedHeader(lines: [String], declaration: Declaration) -> String {
        let end = min(declaration.endLine, declaration.startLine + 2)
        let slice = lines[(declaration.startLine - 1)...(end - 1)]
        let joined = slice.joined(separator: " ")
        let prefix = joined.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? joined
        return prefix
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildLineStates(lines: [String]) -> [LineState] {
        var states: [LineState] = []
        states.reserveCapacity(lines.count)

        var scannerState = ScannerState()
        var braceDepth = 0

        for line in lines {
            let sanitized = sanitize(line, state: &scannerState)
            let startDepth = braceDepth
            braceDepth += sanitized.reduce(into: 0) { partialResult, character in
                if character == "{" {
                    partialResult += 1
                } else if character == "}" {
                    partialResult -= 1
                }
            }
            braceDepth = max(0, braceDepth)
            states.append(LineState(sanitized: sanitized, startDepth: startDepth, endDepth: braceDepth))
        }

        return states
    }

    private static func sanitize(_ line: String, state: inout ScannerState) -> String {
        let characters = Array(line)
        var index = 0
        var output = ""

        while index < characters.count {
            let character = characters[index]

            if state.inBlockComment {
                if character == "*", characters[safe: index + 1] == "/" {
                    state.inBlockComment = false
                    output.append("  ")
                    index += 2
                } else {
                    output.append(" ")
                    index += 1
                }
                continue
            }

            if state.inMultilineString {
                if character == "\"", characters[safe: index + 1] == "\"", characters[safe: index + 2] == "\"" {
                    state.inMultilineString = false
                    output.append("   ")
                    index += 3
                } else {
                    output.append(" ")
                    index += 1
                }
                continue
            }

            if state.inString {
                if character == "\\" {
                    output.append("  ")
                    index += min(2, characters.count - index)
                } else if character == "\"" {
                    state.inString = false
                    output.append(" ")
                    index += 1
                } else {
                    output.append(" ")
                    index += 1
                }
                continue
            }

            if character == "/", characters[safe: index + 1] == "/" {
                output.append(String(repeating: " ", count: characters.count - index))
                break
            }

            if character == "/", characters[safe: index + 1] == "*" {
                state.inBlockComment = true
                output.append("  ")
                index += 2
                continue
            }

            if character == "\"", characters[safe: index + 1] == "\"", characters[safe: index + 2] == "\"" {
                state.inMultilineString = true
                output.append("   ")
                index += 3
                continue
            }

            if character == "\"" {
                state.inString = true
                output.append(" ")
                index += 1
                continue
            }

            output.append(character)
            index += 1
        }

        return output
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ScannerState {
    var inString = false
    var inMultilineString = false
    var inBlockComment = false
}

private struct LineState {
    let sanitized: String
    let startDepth: Int
    let endDepth: Int
}

private struct Declaration {
    let path: String
    let kind: DeclarationKind
    let symbol: String
    let startLine: Int
    let endLine: Int
    let isContainer: Bool
}

private enum DeclarationKind: String, CaseIterable {
    case classDecl = "class"
    case structDecl = "struct"
    case enumDecl = "enum"
    case actorDecl = "actor"
    case protocolDecl = "protocol"
    case extensionDecl = "extension"
    case funcDecl = "func"
    case initDecl = "init"
    case subscriptDecl = "subscript"

    static let containerKinds: [DeclarationKind] = [.classDecl, .structDecl, .enumDecl, .actorDecl, .protocolDecl, .extensionDecl]
    static let callableKinds: [DeclarationKind] = [.funcDecl, .initDecl, .subscriptDecl]

    var isContainer: Bool {
        Self.containerKinds.contains(self)
    }

    var summaryLabel: String {
        switch self {
        case .classDecl: return "class"
        case .structDecl: return "struct"
        case .enumDecl: return "enum"
        case .actorDecl: return "actor"
        case .protocolDecl: return "protocol"
        case .extensionDecl: return "extension"
        case .funcDecl: return "func"
        case .initDecl: return "init"
        case .subscriptDecl: return "subscript"
        }
    }

    var pattern: String {
        let modifiers = #"(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s*)*(?:(?:public|internal|private|fileprivate|open|final|indirect|nonisolated|override|required|convenience|static|class|actor|async|rethrows|throws|mutating|nonmutating|isolated|distributed)\s+)*"#
        switch self {
        case .classDecl: return "^\\s*" + modifiers + #"class\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .structDecl: return "^\\s*" + modifiers + #"struct\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .enumDecl: return "^\\s*" + modifiers + #"enum\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .actorDecl: return "^\\s*" + modifiers + #"actor\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .protocolDecl: return "^\\s*" + modifiers + #"protocol\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .extensionDecl: return "^\\s*" + modifiers + #"extension\s+[A-Za-z_][A-Za-z0-9_<>.:]*"#
        case .funcDecl: return "^\\s*" + modifiers + #"func\s+[A-Za-z_][A-Za-z0-9_]*"#
        case .initDecl: return "^\\s*" + modifiers + #"init\b"#
        case .subscriptDecl: return "^\\s*" + modifiers + #"subscript\b"#
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}